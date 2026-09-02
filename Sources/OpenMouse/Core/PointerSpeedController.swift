import AppKit
import IOKit
import IOKit.hid
import IOKit.hidsystem
import Observation
import os

/// Per-device pointer acceleration, applied by writing HID properties on the event system's
/// service for each mouse.
///
/// This is the vendor-agnostic answer to "change my mouse's DPI": it works on any mouse the HID
/// event system exposes, needs no root and no private symbols. It is *not* a DPI knob — see the
/// 指针速度 section of CLAUDE.md for why the honest name is "pointer speed" and why
/// `HIDPointerResolution`, which would have been the real linear equivalent, is not usable.
///
/// Deliberately not owned by `MouseEngine`: nothing here touches the event tap, so it must keep
/// working while the tap is blocked on Accessibility permission. `UpdateCoordinator` is the
/// closer precedent and this follows its shape.
@MainActor
@Observable
final class PointerSpeedController {
    /// What happened the last time this device's setting was applied.
    ///
    /// Five states rather than a boolean, because collapsing them is precisely the bug this
    /// feature exists not to repeat: with one flag, "mouse is asleep", "this mouse cannot do
    /// it" and "macOS refused the write" all render as a slider that moves and does nothing.
    /// That is the existing HID++ complaint, and Apple is actively dismantling these
    /// properties, so `rejected` is an ordinary outcome rather than an exceptional one.
    enum ApplyState: Equatable {
        /// The user has not enabled this device (or the master switch is off).
        case disabled
        /// Written and confirmed by reading the value back.
        case applied(Double)
        /// No service for this device right now — unplugged, or asleep.
        case offline
        /// The service exists but has no readable acceleration property. Measured rule: a key
        /// that reads back nil never accepts a write, so this is known before trying.
        case unsupported
        /// The write was refused, or claimed success and did not take.
        case rejected

        /// Kept next to the state rather than inside the view so a self-check can pin it: the
        /// failure this feature exists to avoid is exactly these collapsing into one message.
        /// `disabled` has no label because the checkbox already says it.
        var label: String? {
            switch self {
            case .disabled: nil
            case .applied: Strings.pointerStateApplied
            case .offline: Strings.pointerStateOffline
            case .unsupported: Strings.pointerStateUnsupported
            case .rejected: Strings.pointerStateRejected
            }
        }

        var help: String? {
            switch self {
            case .disabled, .applied: nil
            case .offline: Strings.pointerStateOfflineHelp
            case .unsupported: Strings.pointerStateUnsupportedHelp
            case .rejected: Strings.pointerStateRejectedHelp
            }
        }

        /// How much visual weight a status deserves. Split out from the states themselves because
        /// "distinguishable" and "alarming" are different questions: every state must be readable,
        /// but only one of them is something the user asked for and did not get.
        enum Emphasis {
            /// A neutral fact.
            case normal
            /// A fact about the device rather than about the user's request — dim it. Orange here
            /// would demand attention for a device they most likely do not care about.
            case muted
            /// The user asked for something and it did not happen.
            case attention
        }

        var emphasis: Emphasis {
            switch self {
            case .disabled, .applied, .offline: .normal
            case .unsupported: .muted
            case .rejected: .attention
            }
        }

        /// Every case, so the self-check cannot silently stop covering a new one.
        static let allCases: [ApplyState] = [
            .disabled,
            .applied(PointerSpeed.systemDefault),
            .offline,
            .unsupported,
            .rejected,
        ]
    }

    /// A mouse service present in the event system right now.
    struct Discovered: Identifiable, Equatable, Sendable {
        let key: PointerDeviceKey
        let name: String
        let transport: PointerTransport
        let supportsAcceleration: Bool

        var id: PointerDeviceKey { key }
    }

    /// One line of the settings list: everything connected, plus everything configured.
    struct Row: Identifiable, Equatable, Sendable {
        let key: PointerDeviceKey
        let name: String
        let transport: PointerTransport
        let isLive: Bool
        let supportsAcceleration: Bool

        var id: PointerDeviceKey { key }
    }

    static let shared = PointerSpeedController()

    private static let log = Logger(subsystem: "com.openmouse.OpenMouse", category: "pointer")

    private(set) var discovered: [Discovered] = []
    private(set) var states: [PointerDeviceKey: ApplyState] = [:]
    private(set) var isRunning = false

    /// Cached, and deliberately thrown away on every device change and on wake.
    ///
    /// A client's service list goes **permanently** stale across a replug: measured 2026-09-02,
    /// `CopyServices` on a client held through an unplug keeps returning the *dead* service for
    /// that device — `found=yes` with every property reading nil — and never surfaces the new one,
    /// so the mouse looks `.unsupported` forever while a freshly created client reads it fine.
    /// Retrying with the same client can never recover; only a new client can.
    ///
    /// It is cached rather than created per pass because creating one costs ~1.6 ms of IPC against
    /// 0.006 ms to reuse, and dragging the slider reconciles on every step — on the same run loop
    /// as the event tap.
    ///
    /// An `IOHIDServiceClient` is a handle into its client's session, so service handles are never
    /// stored anywhere: each pass re-copies them and drops them before returning. That is what
    /// makes discarding the client safe.
    private var client: IOHIDEventSystemClient?
    private var notifyPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var wakeObserver: NSObjectProtocol?
    private var rescanTask: Task<Void, Never>?

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard !isRunning else {
            reconcile()
            return
        }
        isRunning = true
        startDeviceNotifications()
        observeWake()
        observePreferences()
        reconcile()
        // Recorded because "no permission" is otherwise indistinguishable from "device can't do
        // it" in the log — the same ambiguity that makes the HID++ path hard to diagnose. Writing
        // these properties is not known to require Accessibility; this line is what lets a bug
        // report answer the question instead of guessing.
        Self.log.notice(
            "started trusted=\(AccessibilityPermission.isTrusted, privacy: .public) mice=\(self.discovered.count, privacy: .public)"
        )
    }

    func stop() {
        guard isRunning || client != nil else { return }
        // Restore before the client goes: the service handles used to write the old value are
        // only valid while their parent client is alive.
        restoreEverythingApplied()
        rescanTask?.cancel()
        rescanTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        stopDeviceNotifications()
        client = nil
        states = [:]
        discovered = []
        isRunning = false
        Self.log.notice("stopped")
    }

    // MARK: Reconciliation

    /// The single path that turns preferences into HID writes. Everything — launch, device
    /// arrival, wake, a settings edit — funnels through here so there is one place where the
    /// applied state is decided.
    ///
    /// Runs the pass twice at most: a device that was working and now reads nothing means the
    /// client's view of the event system went stale, not that the mouse changed its mind. Rebuilding
    /// the client is the only recovery, so it self-heals here rather than relying on having
    /// enumerated every possible invalidation cause in the trigger list.
    func reconcile() {
        guard isRunning else { return }
        guard applyPass() == .clientLooksStale else { return }
        Self.log.notice("client view looks stale, rebuilding and retrying")
        invalidateClient()
        _ = applyPass()
    }

    private enum PassOutcome {
        case settled
        case clientLooksStale
    }

    /// True when a device we had successfully applied now reports no readable property at all.
    /// That is the measured signature of a stale client after a replug — the dead service is still
    /// listed, with every property nil — and it is not something a real device does on its own.
    nonisolated static func looksStale(previous: ApplyState?, current: ApplyState) -> Bool {
        guard case .applied = previous, case .unsupported = current else { return false }
        return true
    }

    private func applyPass() -> PassOutcome {
        let client = activeClient()
        let settings = SettingsStore.shared.preferences
        let masterEnabled = settings.enabled
        let previous = states

        var found: [Discovered] = []
        var next: [PointerDeviceKey: ApplyState] = [:]
        var stale = false

        for service in Self.mouseServices(client) {
            guard let key = Self.identity(of: service) else { continue }
            let accelerationKey = Self.accelerationKey(of: service)
            let current = Self.integer(service, accelerationKey)
            found.append(
                Discovered(
                    key: key,
                    name: Self.string(service, kIOHIDProductKey) ?? "",
                    transport: PointerTransport(ioKitValue: Self.string(service, kIOHIDTransportKey)),
                    supportsAcceleration: current != nil
                )
            )

            guard current != nil else {
                // Reported whether or not the user enabled this device: it is a property of the
                // device, and it is the reason the checkbox is unavailable, so it has to be
                // visible *before* anyone tries to check it.
                next[key] = .unsupported
                if Self.looksStale(previous: previous[key], current: .unsupported) {
                    stale = true
                } else if previous[key] != .unsupported {
                    Self.log.notice(
                        "unsupported device vid=\(key.vendorID, privacy: .public) pid=\(key.productID, privacy: .public): \(accelerationKey, privacy: .public) not readable"
                    )
                }
                continue
            }
            guard masterEnabled, let device = settings.pointer.device(for: key), device.enabled else {
                // Not ours to steer. Hand back only what we actually changed: another tool may
                // own this device's value, and "not enabled" must never mean "overwrite".
                if case .applied = previous[key] {
                    next[key] = restore(service, key: accelerationKey) ? .disabled : .rejected
                } else {
                    next[key] = .disabled
                }
                continue
            }
            let state = apply(device.acceleration, to: service, key: accelerationKey)
            next[key] = state
            // Dragging the slider reconciles on every step, so only a real transition is worth
            // a line. Without this the log is unreadable exactly when it is needed.
            if previous[key] != state {
                switch state {
                case .applied(let value):
                    Self.log.notice(
                        "applied vid=\(key.vendorID, privacy: .public) key=\(accelerationKey, privacy: .public) value=\(value, privacy: .public)"
                    )
                case .rejected:
                    Self.log.error(
                        "write failed vid=\(key.vendorID, privacy: .public) key=\(accelerationKey, privacy: .public) value=\(device.acceleration, privacy: .public)"
                    )
                default:
                    break
                }
            }
        }

        // Configured devices with no service right now. Reported as offline rather than dropped:
        // the setting is still real, it just has nothing to act on until the mouse comes back.
        for device in settings.pointer.devices where next[device.key] == nil {
            next[device.key] = masterEnabled && device.enabled ? .offline : .disabled
        }

        discovered = found
        states = next
        return stale ? .clientLooksStale : .settled
    }

    /// True when nothing is left to wait for, which is what lets the post-replug retry chain stop
    /// early instead of always running to its end.
    private var everyEnabledDeviceIsApplied: Bool {
        let settings = SettingsStore.shared.preferences
        guard settings.enabled else { return true }
        for device in settings.pointer.devices where device.enabled {
            guard case .applied = states[device.key] else { return false }
        }
        return true
    }

    /// Explicit user escape hatch. Disables every configured device *and* force-writes the
    /// system value to every live mouse, including ones this process never touched.
    ///
    /// The force-write is why this is a button and not something done automatically: after a
    /// crash there is no record of what was applied, so the only way to recover is to overwrite
    /// — which is acceptable as a deliberate action and not as a background policy.
    func restoreSystemDefaults() {
        for index in SettingsStore.shared.preferences.pointer.devices.indices {
            SettingsStore.shared.preferences.pointer.devices[index].enabled = false
        }
        // Always on a fresh client: this is the button people reach for precisely when things look
        // wrong, which is when a cached view is most likely to be the thing that is wrong.
        invalidateClient()
        for service in Self.mouseServices(activeClient()) {
            let key = Self.accelerationKey(of: service)
            guard Self.integer(service, key) != nil else { continue }
            _ = restore(service, key: key)
        }
        Self.log.notice("restored system defaults on every live mouse")
        reconcile()
    }

    /// Rows the settings list shows. `nonisolated` because it is pure — no event-system access,
    /// no state — which is also what lets a self-check pin the merge: a configured-but-absent
    /// device keeps its row, otherwise unplugging a mouse would make its setting look deleted.
    nonisolated static func rows(
        discovered: [Discovered],
        settings: PointerSpeedSettings
    ) -> [Row] {
        var rows = discovered.map {
            Row(
                key: $0.key,
                name: $0.name,
                transport: $0.transport,
                isLive: true,
                supportsAcceleration: $0.supportsAcceleration
            )
        }
        for device in settings.devices where !rows.contains(where: { $0.key == device.key }) {
            rows.append(
                Row(
                    key: device.key,
                    name: device.name,
                    transport: device.transport,
                    isLive: false,
                    supportsAcceleration: false
                )
            )
        }
        return rows.sorted { lhs, rhs in
            if lhs.isLive != rhs.isLive { return lhs.isLive }
            if lhs.name != rhs.name {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return (lhs.key.vendorID, lhs.key.productID) < (rhs.key.vendorID, rhs.key.productID)
        }
    }

    // MARK: Writing

    private func apply(
        _ value: Double,
        to service: IOHIDServiceClient,
        key: String
    ) -> ApplyState {
        let fixed = PointerSpeed.fixed(value)
        guard write(fixed, to: service, key: key) else { return .rejected }
        // The return value only says the event system accepted the message, so confirm by
        // reading back. LinearMouse discards this return value entirely, which is why its
        // slider silently does nothing on machines where these properties have been retired.
        guard let readBack = Self.integer(service, key),
              abs(PointerSpeed.value(fromFixed: readBack) - PointerSpeed.value(fromFixed: fixed)) < 0.0005 else {
            return .rejected
        }
        return .applied(PointerSpeed.value(fromFixed: fixed))
    }

    /// Restores by reading the live system-wide value, not by replaying one captured at launch.
    /// A captured original goes stale the moment the user moves the system tracking-speed
    /// slider; the system property cannot. Mirrors LinearMouse's `restorePointerAcceleration()`.
    private func restore(_ service: IOHIDServiceClient, key: String) -> Bool {
        let value = Self.systemAcceleration(key: key) ?? PointerSpeed.systemDefault
        let wrote = write(PointerSpeed.fixed(value), to: service, key: key)
        if wrote {
            Self.log.notice("restored key=\(key, privacy: .public) value=\(value, privacy: .public)")
        } else {
            Self.log.error("restore refused key=\(key, privacy: .public)")
        }
        return wrote
    }

    private func write(_ fixed: Int, to service: IOHIDServiceClient, key: String) -> Bool {
        let number = NSNumber(value: Int32(clamping: fixed))
        return IOHIDServiceClientSetProperty(service, key as CFString, number)
    }

    private func restoreEverythingApplied() {
        let applied = Set(
            states.compactMap { entry -> PointerDeviceKey? in
                if case .applied = entry.value { return entry.key }
                return nil
            }
        )
        guard !applied.isEmpty else { return }
        for service in Self.mouseServices(activeClient()) {
            guard let key = Self.identity(of: service), applied.contains(key) else { continue }
            _ = restore(service, key: Self.accelerationKey(of: service))
        }
    }

    // MARK: Triggers

    /// Registry notifications rather than `IOHIDManager`: this needs to know only *that*
    /// devices came and went, and opening HID devices to find that out would drag the Input
    /// Monitoring permission into a feature that otherwise needs no permission at all.
    private func startDeviceNotifications() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Self.log.error("notification port creation failed; device arrival will be missed")
            return
        }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Appearance and termination are separate notifications with separate iterators, and
        // `IOServiceAddMatchingNotification` consumes a reference to the matching dictionary,
        // so each call needs its own.
        IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching("IOHIDDevice"),
            Self.devicesChanged,
            context,
            &matchedIterator
        )
        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOHIDDevice"),
            Self.devicesChanged,
            context,
            &terminatedIterator
        )
        // The iterators arrive pre-loaded with everything already present; draining them is
        // what arms the notification.
        Self.drain(matchedIterator)
        Self.drain(terminatedIterator)
    }

    private func stopDeviceNotifications() {
        if matchedIterator != 0 {
            IOObjectRelease(matchedIterator)
            matchedIterator = 0
        }
        if terminatedIterator != 0 {
            IOObjectRelease(terminatedIterator)
            terminatedIterator = 0
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
        }
        notifyPort = nil
    }

    private static let devicesChanged: IOServiceMatchingCallback = { context, iterator in
        // Draining is mandatory: IOKit stops delivering to an iterator that still holds
        // entries from the previous notification.
        drain(iterator)
        guard let context else { return }
        MainActor.assumeIsolated {
            Unmanaged<PointerSpeedController>
                .fromOpaque(context)
                .takeUnretainedValue()
                .scheduleRescan()
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }

    /// One device arriving fans out into several registry entries, and a replug invalidates the
    /// cached client outright, so the client is dropped before re-scanning.
    ///
    /// The chain of attempts exists because a device's service is not necessarily published the
    /// instant its registry entry appears. It stops as soon as everything the user enabled is
    /// applied, so the common case costs one pass.
    private func scheduleRescan() {
        rescanTask?.cancel()
        // Logged unconditionally: when this feature failed in the field, the first unanswerable
        // question was whether the notification had fired at all.
        Self.log.notice("device change, rescanning")
        rescanTask = Task { @MainActor [weak self] in
            for delay in Self.rescanDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.isRunning else { return }
                self.invalidateClient()
                self.reconcile()
                if self.everyEnabledDeviceIsApplied { return }
            }
        }
    }

    /// Intervals between attempts, i.e. roughly 0.4s / 1.2s / 3s / 6s after the device event.
    private static let rescanDelays: [Duration] = [
        .milliseconds(400),
        .milliseconds(800),
        .milliseconds(1_800),
        .seconds(3),
    ]

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Sleep can retire and republish services without a registry notification we
                // subscribed to, so the client is assumed stale here too.
                self?.invalidateClient()
                self?.reconcile()
            }
        }
    }

    private func observePreferences() {
        withObservationTracking {
            _ = SettingsStore.shared.preferences.pointer
            _ = SettingsStore.shared.preferences.enabled
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.reconcile()
                self.observePreferences()
            }
        }
    }

    // MARK: Event system access

    private func activeClient() -> IOHIDEventSystemClient {
        if let client { return client }
        let created = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        client = created
        return created
    }

    /// Drops the cached client so the next pass builds one that can actually see the current
    /// devices. Safe at any point because no service handle is ever stored.
    private func invalidateClient() {
        client = nil
    }

    /// Conforming to GenericDesktop/Mouse is a necessary but nowhere near sufficient filter: on
    /// this machine it also matches a keyboard and Karabiner's virtual pointing device, and
    /// `kIOHIDBuiltInKey` is nil on all of them so it cannot separate them either. That is why
    /// the user picks devices from a list instead of the app guessing.
    private static func mouseServices(_ client: IOHIDEventSystemClient) -> [IOHIDServiceClient] {
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else {
            return []
        }
        return services.filter {
            IOHIDServiceClientConformsTo(
                $0,
                UInt32(kHIDPage_GenericDesktop),
                UInt32(kHIDUsage_GD_Mouse)
            ) != 0
        }
    }

    /// The service names the property it actually consults, so read it rather than hardcoding a
    /// device-type guess. A trackpad service would name its own key this way.
    private static func accelerationKey(of service: IOHIDServiceClient) -> String {
        string(service, kIOHIDPointerAccelerationTypeKey) ?? kIOHIDMouseAccelerationTypeKey
    }

    private static func identity(of service: IOHIDServiceClient) -> PointerDeviceKey? {
        guard let vendorID = integer(service, kIOHIDVendorIDKey),
              let productID = integer(service, kIOHIDProductIDKey) else { return nil }
        return PointerDeviceKey(vendorID: vendorID, productID: productID)
    }

    private static func property(_ service: IOHIDServiceClient, _ key: String) -> CFTypeRef? {
        IOHIDServiceClientCopyProperty(service, key as CFString)
    }

    private static func integer(_ service: IOHIDServiceClient, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }

    private static func string(_ service: IOHIDServiceClient, _ key: String) -> String? {
        property(service, key) as? String
    }

    /// The system-wide value behind 系统设置 › 鼠标 › 跟踪速度. All public IOKit; verified
    /// unprivileged on macOS 26.6.
    private static func systemAcceleration(key: String) -> Double? {
        let service = IORegistryEntryFromPath(
            kIOMainPortDefault,
            "\(kIOServicePlane):/IOResources/IOHIDSystem"
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var handle: io_connect_t = 0
        guard IOServiceOpen(
            service,
            mach_task_self_,
            UInt32(kIOHIDParamConnectType),
            &handle
        ) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(handle) }

        var valueRef: Unmanaged<CFTypeRef>?
        guard IOHIDCopyCFTypeParameter(handle, key as CFString, &valueRef) == KERN_SUCCESS,
              let number = valueRef?.takeRetainedValue() as? NSNumber else { return nil }
        return PointerSpeed.value(fromFixed: number.intValue)
    }
}
