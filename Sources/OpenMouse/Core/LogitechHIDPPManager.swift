import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import os

/// Pure HID++ facts kept separate from IOKit lifecycle so regressions can be asserted without
/// opening a real device. Values are protocol identifiers, not copied implementation code.
enum LogitechHIDPPProtocol {
    static let adjustableDPIFeature: UInt16 = 0x2201

    /// Logical button numbers are persisted in the existing binding model. Keep the DPI
    /// assignment stable and give M720's physical thumb control its own extra-button number:
    /// aliasing Forward (4) would make the two physical buttons share one shortcut.
    static let dpiSwitchButton = 5
    static let m720ThumbButton = 6

    static let cidToButton: [UInt16: Int] = [
        0x0052: 2, // middle
        0x0053: 3, // back
        0x0056: 4, // forward
        0x00C3: 4, // Logitech Gesture
        0x00D0: m720ThumbButton, // M720 physical thumb; not the virtual 0x00D7 control
        0x00D7: 4, // Logitech Virtual Gesture
        0x00FD: dpiSwitchButton // DPI Switch
    ]

    /// Controls that do not emit a usable native `CGEvent` before they have been diverted. They
    /// must be owned temporarily while the recorder is open, otherwise there is no first press
    /// from which a user can create a binding.
    static let captureOnlyButtons: Set<Int> = [dpiSwitchButton, m720ThumbButton]

    struct Control {
        let cid: UInt16
        let divertable: Bool
    }

    struct ButtonState {
        private(set) var held: Set<Int> = []

        mutating func update(_ now: Set<Int>) -> (pressed: Set<Int>, released: Set<Int>) {
            let pressed = now.subtracting(held)
            let released = held.subtracting(now)
            held = now
            return (pressed, released)
        }
    }

    static func desiredButtons(configured: Set<Int>, capturing: Bool) -> Set<Int> {
        guard capturing else { return configured }
        return configured.union(captureOnlyButtons)
    }

    /// Recording may request controls absent from this model. Only touch controls the device
    /// actually advertised as divertable; M720's thumb capture does not depend on a DPI feature.
    static func desiredCIDs(controls: [Control], buttons: Set<Int>) -> Set<UInt16> {
        Set(controls.compactMap { control in
            guard control.divertable, let button = cidToButton[control.cid],
                  buttons.contains(button) else { return nil }
            return control.cid
        })
    }

    static func reportingParameters(cid: UInt16, divert: Bool) -> [UInt8] {
        [UInt8(cid >> 8), UInt8(cid & 0xFF), divert ? 0x03 : 0x02, 0x00, 0x00]
    }

    static func setDPIParameters(_ dpi: Int) -> [UInt8] {
        [0x00, UInt8((dpi >> 8) & 0xFF), UInt8(dpi & 0xFF)]
    }

    static func dpi(from report: [UInt8]) -> Int? {
        guard report.count >= 7, report[4] == 0 else { return nil }
        return (Int(report[5]) << 8) | Int(report[6])
    }

    static func activeButtons(in report: [UInt8], ownedCIDs: Set<UInt16>) -> Set<Int> {
        guard report.count >= 6 else { return [] }
        var buttons = Set<Int>()
        var offset = 4
        while offset + 1 < report.count {
            let cid = (UInt16(report[offset]) << 8) | UInt16(report[offset + 1])
            if cid == 0 { break }
            if ownedCIDs.contains(cid), let button = cidToButton[cid] { buttons.insert(button) }
            offset += 2
        }
        return buttons
    }
}

/// Device discovery must never open every Logitech interface. A keyboard seized by
/// Karabiner would otherwise make IOHIDManagerOpen fail for the mouse as well, before
/// the per-device callback has a chance to reject that keyboard.
///
/// Independent devices keep discovery separate from access: only an accepted mouse's
/// session opens/schedules it, and an inaccessible mouse cannot stop other sessions.
enum LogitechHIDPPDevicePolicy {
    static let vendorID = 0x046D
    static let managerOptions = IOHIDManagerOptions.independentDevices.rawValue
    static let matchingCriteria: [String: Int] = [
        kIOHIDVendorIDKey: vendorID,
        kIOHIDDeviceUsagePageKey: 0x0001,
        kIOHIDDeviceUsageKey: 0x0002
    ]

    static func accepts(
        vendorID: Int,
        primaryUsagePage: Int,
        primaryUsage: Int,
        transport: String
    ) -> Bool {
        vendorID == Self.vendorID
            && primaryUsagePage == 0x0001
            && primaryUsage == 0x0002
            && transport.lowercased().contains("bluetooth")
    }
}

/// Minimal, clean-room HID++ 2.0 input support for Logitech mice.
///
/// The normal CGEvent path is still the default for generic mice. Logitech BLE mice are a
/// special case: several models expose Back/Forward as a momentary native click even while the
/// physical button remains held. That is sufficient for browser navigation, but it destroys a
/// hold-and-drag gesture because macOS reports mouse-up a few milliseconds after mouse-down.
///
/// HID++ `REPROG_CONTROLS_V4` can divert only the controls Open Mouse has actually bound and
/// reports the complete set of physically-held CIDs on every transition. We derive down/up from
/// that set and feed the existing EventRouter; pointer movement remains on the normal event tap.
@MainActor
final class LogitechHIDPPManager {
    typealias ButtonHandler = (_ button: Int, _ isDown: Bool) -> Void
    typealias DPIHandler = (_ currentDPI: Int?) -> Void

    private static let log = Logger(subsystem: "com.openmouse.OpenMouse", category: "hidpp")

    private let onButton: ButtonHandler
    private let onButtonCancelled: (Int) -> Void
    private let onOwnedButtonsChanged: (Set<Int>) -> Void
    private var buttonOwners = LogitechHIDPPButtonOwners()
    private var onDPIChanged: DPIHandler?
    private var currentDPI: Int?
    private var manager: IOHIDManager?
    private var sessions: [IOHIDDevice: LogitechHIDPPDeviceSession] = [:]
    private var receivers: [UInt64: LogitechUnifyingReceiver] = [:]
    private var retiringReceivers: [UInt64: (id: UUID, transport: LogitechUnifyingTransport)] = [:]
    private var deferredReceivers: [UInt64: IOHIDDevice] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var desiredButtons: Set<Int> = []
    private(set) var isRunning = false
    private lazy var receiverDiscovery = LogitechUnifyingDiscovery(onMatched: { [weak self] id, device in
        self?.attachReceiver(id: id, device: device)
    }, onRemoved: { [weak self] id in
        self?.deferredReceivers.removeValue(forKey: id)
        self?.retireReceiver(id: id, restoreControls: false)
    })

    init(
        onButton: @escaping ButtonHandler,
        onButtonCancelled: ((Int) -> Void)? = nil,
        onOwnedButtonsChanged: @escaping (Set<Int>) -> Void
    ) {
        self.onButton = onButton
        self.onButtonCancelled = onButtonCancelled ?? { onButton($0, false) }
        self.onOwnedButtonsChanged = onOwnedButtonsChanged
    }

    func start() {
        guard !isRunning else { return }
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            LogitechHIDPPDevicePolicy.managerOptions
        )
        self.manager = manager
        IOHIDManagerSetDeviceMatching(
            manager,
            LogitechHIDPPDevicePolicy.matchingCriteria as CFDictionary
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            Self.log.error("manager open failed result=0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
            return
        }
        isRunning = true
        Self.log.notice("manager started")
        receiverDiscovery.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.receiverDiscovery.rescan()
                for receiver in self.receivers.values { receiver.rescan() }
            }
        }
    }

    func stop() {
        guard isRunning || manager != nil else { return }
        receiverDiscovery.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        deferredReceivers.removeAll()
        for id in Array(receivers.keys) { retireReceiver(id: id, restoreControls: true) }
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        publishOwnedButtons()
        publishDPI(nil)
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
        }
        self.manager = nil
        isRunning = false
        Self.log.notice("manager stopped")
    }

    func updateDesiredButtons(_ buttons: Set<Int>) {
        desiredButtons = buttons
        for session in sessions.values { session.updateDesiredButtons(buttons) }
        for receiver in receivers.values { receiver.updateDesiredButtons(buttons) }
    }

    func prepareButtonCapture() {
        guard isRunning else { return }
        receiverDiscovery.rescan()
        for receiver in receivers.values { receiver.prepareForCapture() }
    }

    /// Called only after the event taps have stopped, at process exit. Receiver IO and its
    /// restoration callbacks live off-main, so this bounded wait cannot starve their replies.
    func flushPendingReceiverStops() {
        let deadline = DispatchTime.now() + LogitechUnifyingProtocol.exitFlushTimeout
        for item in retiringReceivers.values {
            if !item.transport.waitUntilStopped(deadline: deadline) {
                Self.log.error("Unifying vendor interface did not finish stopping before exit")
            }
        }
    }

    func setDPIHandler(_ handler: DPIHandler?) {
        onDPIChanged = handler
        handler?(currentDPI)
    }

    func refreshDPI() {
        for session in sessions.values { session.refreshDPI() }
    }

    func toggleDPI(_ levels: LogitechDPILevels) {
        guard !sessions.isEmpty else {
            Self.log.error("DPI toggle unavailable: no Logitech HID++ mouse session")
            return
        }
        for session in sessions.values { session.toggleDPI(levels) }
    }

    private static let deviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        MainActor.assumeIsolated {
            Unmanaged<LogitechHIDPPManager>
                .fromOpaque(context)
                .takeUnretainedValue()
                .attach(device)
        }
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        MainActor.assumeIsolated {
            Unmanaged<LogitechHIDPPManager>
                .fromOpaque(context)
                .takeUnretainedValue()
                .detach(device)
        }
    }

    private func attach(_ device: IOHIDDevice) {
        guard sessions[device] == nil else { return }
        let usagePage = propertyInt(device, kIOHIDPrimaryUsagePageKey)
        let usage = propertyInt(device, kIOHIDPrimaryUsageKey)
        let transport = propertyString(device, kIOHIDTransportKey)
        let name = propertyString(device, kIOHIDProductKey)

        // BLE HID++ shares the regular mouse interface. Other standard interfaces, notably
        // keyboards, must not be opened merely because they use Logitech's vendor ID.
        guard LogitechHIDPPDevicePolicy.accepts(
            vendorID: propertyInt(device, kIOHIDVendorIDKey),
            primaryUsagePage: usagePage,
            primaryUsage: usage,
            transport: transport
        ) else { return }

        let source = UUID()
        let session = LogitechHIDPPDeviceSession(
            device: device,
            name: name.isEmpty ? "Logitech mouse" : name,
            productID: propertyInt(device, kIOHIDProductIDKey),
            onButton: { [weak self] button, down in self?.handleButton(source: source, button: button, isDown: down) },
            onCancelButton: { [weak self] button in self?.cancelButton(source: source, button: button) },
            onOwnershipChanged: { [weak self] in self?.publishOwnedButtons() },
            onDPIChanged: { [weak self] dpi in self?.publishDPI(dpi) }
        )
        sessions[device] = session
        session.updateDesiredButtons(desiredButtons)
        session.start()
    }

    private func detach(_ device: IOHIDDevice) {
        guard let session = sessions.removeValue(forKey: device) else { return }
        session.stop(cancelHeld: true)
        publishOwnedButtons()
        if sessions.isEmpty { publishDPI(nil) }
    }

    private func attachReceiver(id: UInt64, device: IOHIDDevice) {
        guard isRunning, receivers[id] == nil else { return }
        // Do not open the same physical interface until the old instance has restored its
        // control and completed HID cancellation. Otherwise its late clear can undo re-enable.
        if let old = retiringReceivers[id], !old.transport.isStopped {
            deferredReceivers[id] = device
            return
        }
        retiringReceivers.removeValue(forKey: id)
        let source = UUID()
        let receiver = LogitechUnifyingReceiver(
            device: device,
            onButton: { [weak self] button, down in self?.handleButton(source: source, button: button, isDown: down) },
            onCancelButton: { [weak self] button in self?.cancelButton(source: source, button: button) },
            onOwnershipChanged: { [weak self] in self?.publishOwnedButtons() },
            onStopped: { [weak self] token in self?.receiverStopped(id: id, token: token) }
        )
        receivers[id] = receiver
        receiver.updateDesiredButtons(desiredButtons)
        Self.log.notice("Unifying vendor interface discovered registryID=\(id)")
        receiver.start()
    }

    private func retireReceiver(id: UInt64, restoreControls: Bool) {
        guard let receiver = receivers.removeValue(forKey: id) else { return }
        retiringReceivers[id] = (receiver.id, receiver.transport)
        receiver.stop(restoreControls: restoreControls)
        publishOwnedButtons()
    }

    private func receiverStopped(id: UInt64, token: UUID) {
        if receivers[id]?.id == token {
            receivers.removeValue(forKey: id)?.stop(restoreControls: false)
            publishOwnedButtons()
        }
        if retiringReceivers[id]?.id == token { retiringReceivers.removeValue(forKey: id) }
        if isRunning, let device = deferredReceivers.removeValue(forKey: id), receiverDiscovery.presentIDs.contains(id) {
            attachReceiver(id: id, device: device)
        }
    }

    private func handleButton(source: UUID, button: Int, isDown: Bool) {
        if buttonOwners.update(source: source, button: button, isDown: isDown) { onButton(button, isDown) }
    }

    private func cancelButton(source: UUID, button: Int) {
        if buttonOwners.update(source: source, button: button, isDown: false) { onButtonCancelled(button) }
    }

    private func publishDPI(_ dpi: Int?) {
        guard currentDPI != dpi else { return }
        currentDPI = dpi
        onDPIChanged?(dpi)
    }

    private func publishOwnedButtons() {
        var buttons = sessions.values.reduce(into: Set<Int>()) { result, session in
            result.formUnion(session.ownedButtons)
        }
        for receiver in receivers.values { buttons.formUnion(receiver.ownedButtons) }
        onOwnedButtonsChanged(buttons)
    }

    private func propertyInt(_ device: IOHIDDevice, _ key: String) -> Int {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? 0
    }

    private func propertyString(_ device: IOHIDDevice, _ key: String) -> String {
        IOHIDDeviceGetProperty(device, key as CFString) as? String ?? ""
    }
}

@MainActor
final class LogitechHIDPPDeviceSession {
    private enum ProtocolStage: Equatable {
        case idle
        case feature
        case count
        case control(index: Int, count: Int)
        case ready
        case failed
    }

    private enum DPIToggleStage: Equatable {
        case idle
        case feature
        case current
        case write(target: Int)
    }

    private static let log = Logger(subsystem: "com.openmouse.OpenMouse", category: "hidpp")
    private static let longReportID: UInt8 = 0x11
    private static let reprogControlsV4: UInt16 = 0x1B04
    private static let reportSize = 20

    private let device: IOHIDDevice?
    private let deviceIndex: UInt8
    private let externalSend: (([UInt8]) -> Bool)?
    private let allowedButtons: Set<Int>?
    private let supportsDPI: Bool
    private let name: String
    private let productID: Int
    private let onButton: LogitechHIDPPManager.ButtonHandler
    private let onCancelButton: ((Int) -> Void)?
    private let onOwnershipChanged: () -> Void
    private let onDPIChanged: (Int) -> Void
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var opened = false
    private var stopped = false
    private var stage: ProtocolStage = .idle
    private var reprogFeatureIndex: UInt8?
    private var controls: [LogitechHIDPPProtocol.Control] = []
    private var desiredButtons: Set<Int> = []
    private var divertedCIDs: Set<UInt16> = []
    private var buttonState = LogitechHIDPPProtocol.ButtonState()
    private var timeout: DispatchWorkItem?
    private var dpiFeatureIndex: UInt8?
    private var dpiLevels: LogitechDPILevels?
    private var dpiStage: DPIToggleStage = .idle
    private var dpiTimeout: DispatchWorkItem?
    private var dpiRefreshCache = LogitechDPIRefreshCache()
    private var dpiRequestID: UUID?

    var ownedButtons: Set<Int> {
        Set(divertedCIDs.compactMap { LogitechHIDPPProtocol.cidToButton[$0] })
    }

    var needsRecovery: Bool { stage == .failed }

    /// Capture these before stopping a borrowed receiver session. Its shared transport owns
    /// the asynchronous restore/close sequence, not this peripheral's protocol state.
    var restorationReports: [[UInt8]] {
        guard let feature = reprogFeatureIndex else { return [] }
        return divertedCIDs.sorted().map { cid in
            report(featureIndex: feature, function: 3,
                   params: LogitechHIDPPProtocol.reportingParameters(cid: cid, divert: false))
        }
    }

    init(
        device: IOHIDDevice? = nil,
        name: String,
        productID: Int,
        deviceIndex: UInt8 = 0xFF,
        allowedButtons: Set<Int>? = nil,
        supportsDPI: Bool = true,
        sendReport: (([UInt8]) -> Bool)? = nil,
        onButton: @escaping LogitechHIDPPManager.ButtonHandler,
        onCancelButton: ((Int) -> Void)? = nil,
        onOwnershipChanged: @escaping () -> Void,
        onDPIChanged: @escaping (Int) -> Void
    ) {
        precondition(device != nil || sendReport != nil)
        precondition(deviceIndex == 0xFF || LogitechUnifyingProtocol.slots.contains(deviceIndex))
        self.device = device
        self.deviceIndex = deviceIndex
        self.allowedButtons = allowedButtons
        self.supportsDPI = supportsDPI
        externalSend = sendReport
        self.name = name
        self.productID = productID
        self.onButton = onButton
        self.onCancelButton = onCancelButton
        self.onOwnershipChanged = onOwnershipChanged
        self.onDPIChanged = onDPIChanged
    }

    deinit {
        timeout?.cancel()
        dpiTimeout?.cancel()
        reportBuffer?.deallocate()
    }

    func start() {
        guard stage == .idle else { return }
        if let device {
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            opened = result == kIOReturnSuccess
            guard opened else {
                stage = .failed
                Self.log.error("\(self.name, privacy: .public) open failed result=0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
                return
            }

            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            buffer.initialize(repeating: 0, count: 64)
            reportBuffer = buffer
            IOHIDDeviceRegisterInputReportCallback(
                device, buffer, 64, Self.inputReport,
                Unmanaged.passUnretained(self).toOpaque()
            )
            // BLE owns its interface. A receiver peripheral borrows one shared transport and
            // must never open/close or replace its sibling slots' input-report callback.
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }

        Self.log.notice("device connected name=\(self.name, privacy: .public) pid=0x\(String(self.productID, radix: 16), privacy: .public) slot=\(self.deviceIndex)")
        stage = .feature
        armTimeout(label: "feature discovery")
        if !send(featureIndex: 0x00, function: 0, params: [0x1B, 0x04]) {
            timeout?.cancel()
            stage = .failed
        }
    }

    func stop(restoreControls: Bool = true, cancelHeld: Bool = false) {
        guard !stopped else { return }
        stopped = true
        timeout?.cancel()
        timeout = nil
        dpiTimeout?.cancel()
        dpiTimeout = nil
        dpiStage = .idle
        dpiLevels = nil
        dpiRequestID = nil
        dpiRefreshCache = LogitechDPIRefreshCache()
        if cancelHeld { cancelAllButtons() }
        else { releaseAllButtons() }
        if restoreControls, let feature = reprogFeatureIndex {
            for cid in divertedCIDs.sorted() {
                _ = setReporting(featureIndex: feature, cid: cid, divert: false)
            }
        }
        divertedCIDs.removeAll()
        onOwnershipChanged()
        if opened, let device {
            IOHIDDeviceUnscheduleFromRunLoop(
                device,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            if let reportBuffer {
                IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, nil, nil)
            }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            opened = false
        }
        Self.log.notice("device stopped name=\(self.name, privacy: .public)")
    }

    func updateDesiredButtons(_ buttons: Set<Int>) {
        desiredButtons = allowedButtons.map { buttons.intersection($0) } ?? buttons
        if stage == .ready { applyDesiredDiverts() }
    }

    func refreshDPI() {
        guard supportsDPI, stage == .ready, dpiStage == .idle,
              dpiRefreshCache.needsRefresh(at: ProcessInfo.processInfo.systemUptime) else { return }
        beginDPIRequest(levels: nil)
    }

    func toggleDPI(_ levels: LogitechDPILevels) {
        guard supportsDPI else {
            Self.log.error("\(self.name, privacy: .public) receiver path only supports the M720 thumb control, not DPI")
            return
        }
        guard stage == .ready else {
            Self.log.error("\(self.name, privacy: .public) DPI toggle unavailable before HID++ discovery is ready")
            return
        }
        guard dpiStage == .idle else {
            // Startup/page-open refreshes are read-only. If the user presses the DPI key while
            // that read is in flight, promote the same request into a toggle instead of dropping
            // the physical press.
            if dpiLevels == nil {
                dpiLevels = levels
                Self.log.notice("\(self.name, privacy: .public) current DPI read promoted to toggle")
            } else {
                Self.log.notice("\(self.name, privacy: .public) DPI toggle ignored while another toggle is active")
            }
            return
        }
        beginDPIRequest(levels: levels)
    }

    private func beginDPIRequest(levels: LogitechDPILevels?) {
        // A real DPI press deliberately bypasses the UI cache/backoff: always read the device
        // before choosing the other level. Page opens share the existing in-flight request.
        dpiRequestID = UUID()
        dpiLevels = levels
        if let feature = dpiFeatureIndex {
            requestCurrentDPI(featureIndex: feature)
        } else {
            dpiStage = .feature
            armDPITimeout(label: "DPI feature discovery")
            guard sendDPIReport(
                featureIndex: 0x00,
                function: 0,
                params: [
                    UInt8(LogitechHIDPPProtocol.adjustableDPIFeature >> 8),
                    UInt8(LogitechHIDPPProtocol.adjustableDPIFeature & 0xFF)
                ]
            ) else {
                finishDPIRequest(error: "feature discovery send failed")
                return
            }
        }
    }

    private static let inputReport: IOHIDReportCallback = {
        context, _, _, _, reportID, report, reportLength in
        guard let context, reportLength >= 0, reportLength <= 64 else { return }
        let session = Unmanaged<LogitechHIDPPDeviceSession>
            .fromOpaque(context)
            .takeUnretainedValue()
        var bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
        let id = UInt8(truncatingIfNeeded: reportID)
        if bytes.first != id, id != 0 { bytes.insert(id, at: 0) }
        MainActor.assumeIsolated { session.receive(bytes) }
    }

    func receive(_ report: [UInt8]) {
        guard !stopped, LogitechUnifyingProtocol.isValidReport(report),
              report[1] == deviceIndex else { return }

        let feature = report[2]
        let function = report[3] >> 4
        let softwareID = report[3] & 0x0F

        if let error = LogitechUnifyingProtocol.errorCode(in: report) {
            if dpiStage != .idle {
                finishDPIRequest(error: "HID++ error code=0x\(String(error, radix: 16))")
                return
            }
            timeout?.cancel()
            stage = .failed
            Self.log.error("\(self.name, privacy: .public) HID++ error feature=0x\(String(report[3], radix: 16), privacy: .public) code=0x\(String(error, radix: 16), privacy: .public)")
            return
        }

        if handleDPIResponse(
            report,
            feature: feature,
            function: function,
            softwareID: softwareID
        ) {
            return
        }

        switch stage {
        case .feature where feature == 0x00 && function == 0 && softwareID == 0x01:
            timeout?.cancel()
            let index = report[4]
            guard index != 0 else {
                stage = .failed
                Self.log.notice("\(self.name, privacy: .public) has no REPROG_CONTROLS_V4")
                return
            }
            reprogFeatureIndex = index
            stage = .count
            Self.log.notice("\(self.name, privacy: .public) REPROG_CONTROLS_V4 index=0x\(String(index, radix: 16), privacy: .public)")
            armTimeout(label: "control count")
            _ = send(featureIndex: index, function: 0)
            return

        case .count where feature == reprogFeatureIndex && function == 0 && softwareID == 0x01:
            timeout?.cancel()
            let count = Int(report[4])
            Self.log.notice("\(self.name, privacy: .public) programmable controls=\(count)")
            controls.removeAll(keepingCapacity: true)
            guard count > 0, let index = reprogFeatureIndex else {
                stage = .ready
                applyDesiredDiverts()
                refreshDPI()
                return
            }
            stage = .control(index: 0, count: count)
            armTimeout(label: "control 0")
            _ = send(featureIndex: index, function: 1, params: [0])
            return

        case let .control(index, count)
            where feature == reprogFeatureIndex && function == 1 && softwareID == 0x01:
            timeout?.cancel()
            let cid = (UInt16(report[4]) << 8) | UInt16(report[5])
            let flagsLow = UInt16(report[8])
            let flagsHigh = report.count > 12 ? UInt16(report[12]) << 8 : 0
            let flags = flagsLow | flagsHigh
            let divertable = flags & 0x20 != 0
            controls.append(.init(cid: cid, divertable: divertable))
            let button = LogitechHIDPPProtocol.cidToButton[cid]
            Self.log.notice("\(self.name, privacy: .public) control cid=0x\(String(cid, radix: 16), privacy: .public) button=\(button ?? -1) divertable=\(divertable)")
            let next = index + 1
            if next < count, let feature = reprogFeatureIndex {
                stage = .control(index: next, count: count)
                armTimeout(label: "control \(next)")
                _ = send(featureIndex: feature, function: 1, params: [UInt8(next)])
            } else {
                stage = .ready
                Self.log.notice("\(self.name, privacy: .public) HID++ discovery ready")
                applyDesiredDiverts()
                refreshDPI()
            }
            return

        default:
            break
        }

        guard stage == .ready,
              feature == reprogFeatureIndex,
              function == 0,
              softwareID == 0x00 else { return }
        handleDivertedButtons(report)
    }

    private func applyDesiredDiverts() {
        guard stage == .ready, let feature = reprogFeatureIndex else { return }
        let desiredCIDs = LogitechHIDPPProtocol.desiredCIDs(
            controls: controls,
            buttons: desiredButtons
        )

        let toRelease = divertedCIDs.subtracting(desiredCIDs)
        for cid in toRelease.sorted() {
            if setReporting(featureIndex: feature, cid: cid, divert: false) {
                divertedCIDs.remove(cid)
            }
        }
        for cid in desiredCIDs.subtracting(divertedCIDs).sorted() {
            if setReporting(featureIndex: feature, cid: cid, divert: true) {
                divertedCIDs.insert(cid)
            }
        }
        // Closing the recorder or removing a binding can restore native reporting before the
        // physical up. No HID++ release may follow, so retire only claims we no longer own now;
        // leaving the old hold cached would also hide the next first press after re-capture.
        publishButtonState(buttonState.held.intersection(ownedButtons))
        onOwnershipChanged()
    }

    private func handleDPIResponse(
        _ report: [UInt8],
        feature: UInt8,
        function: UInt8,
        softwareID: UInt8
    ) -> Bool {
        switch dpiStage {
        case .feature where feature == 0x00 && function == 0 && softwareID == 0x01:
            dpiTimeout?.cancel()
            let index = report[4]
            guard index != 0 else {
                dpiRefreshCache.markUnsupported()
                finishDPIRequest(error: "device has no ADJUSTABLE_DPI feature")
                return true
            }
            dpiFeatureIndex = index
            requestCurrentDPI(featureIndex: index)
            return true

        case .current
            where feature == dpiFeatureIndex && function == 2 && softwareID == 0x01:
            dpiTimeout?.cancel()
            guard let current = LogitechHIDPPProtocol.dpi(from: report) else {
                finishDPIRequest(error: "invalid current DPI response")
                return true
            }
            dpiRefreshCache.recordSuccess(at: ProcessInfo.processInfo.systemUptime)
            onDPIChanged(current)
            guard let levels = dpiLevels else {
                finishDPIRead(current: current)
                return true
            }
            guard let feature = dpiFeatureIndex else {
                finishDPIRequest(error: "missing DPI feature index")
                return true
            }
            let target = levels.target(after: current)
            dpiStage = .write(target: target)
            armDPITimeout(label: "write \(target) DPI")
            guard sendDPIReport(
                featureIndex: feature,
                function: 3,
                params: LogitechHIDPPProtocol.setDPIParameters(target)
            ) else {
                finishDPIRequest(error: "write send failed")
                return true
            }
            Self.log.notice("\(self.name, privacy: .public) DPI toggle current=\(current) target=\(target)")
            return true

        case let .write(target)
            where feature == dpiFeatureIndex && function == 3 && softwareID == 0x01:
            dpiRefreshCache.recordSuccess(at: ProcessInfo.processInfo.systemUptime)
            onDPIChanged(target)
            finishDPIToggle(success: target)
            return true

        default:
            return false
        }
    }

    private func requestCurrentDPI(featureIndex: UInt8) {
        dpiStage = .current
        armDPITimeout(label: "read current DPI")
        guard sendDPIReport(featureIndex: featureIndex, function: 2, params: [0x00]) else {
            finishDPIRequest(error: "current DPI request send failed")
            return
        }
    }

    private func finishDPIRead(current: Int) {
        resetDPIRequest()
        Self.log.notice("\(self.name, privacy: .public) current DPI=\(current)")
    }

    private func finishDPIToggle(success target: Int) {
        resetDPIRequest()
        Self.log.notice("\(self.name, privacy: .public) DPI changed to \(target)")
    }

    private func finishDPIRequest(error: String) {
        dpiRefreshCache.recordFailure(at: ProcessInfo.processInfo.systemUptime)
        resetDPIRequest()
        Self.log.error("\(self.name, privacy: .public) DPI request failed: \(error, privacy: .public)")
    }

    private func resetDPIRequest() {
        dpiRequestID = nil
        dpiTimeout?.cancel()
        dpiTimeout = nil
        dpiStage = .idle
        dpiLevels = nil
    }

    @discardableResult
    private func setReporting(featureIndex: UInt8, cid: UInt16, divert: Bool) -> Bool {
        let ok = send(
            featureIndex: featureIndex,
            function: 3,
            params: LogitechHIDPPProtocol.reportingParameters(cid: cid, divert: divert)
        )
        Self.log.notice("\(self.name, privacy: .public) cid=0x\(String(cid, radix: 16), privacy: .public) divert=\(divert) sent=\(ok)")
        return ok
    }

    /// DPI reads/writes must never wait for Bluetooth on the main run loop. In particular,
    /// `onAppear` runs before the Buttons form's first frame; the synchronous API used to
    /// hold that frame (and the event tap) on every visit. Do not add a synchronous fallback.
    @discardableResult
    private func sendDPIReport(featureIndex: UInt8, function: UInt8, params: [UInt8] = []) -> Bool {
        guard let device else { return false }
        let requestID = dpiRequestID
        let expectedStage = dpiStage
        let result = HIDAsyncReport.send(
            report(featureIndex: featureIndex, function: function, params: params),
            submit: { bytes, count, callback, context in
                IOHIDDeviceSetReportWithCallback(
                    device, kIOHIDReportTypeOutput, CFIndex(Self.longReportID),
                    bytes, count, 1_000, callback, context
                )
            },
            completion: { [weak self] result in
                guard result != kIOReturnSuccess else { return }
                // IOKit completes on the scheduled run loop. Defer teardown (including an
                // abort delivered by UnscheduleFromRunLoop) and ignore obsolete completions.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped,
                          self.dpiRequestID == requestID, self.dpiStage == expectedStage else { return }
                    self.finishDPIRequest(error: "async send failed: \(result)")
                }
            }
        )
        return result == kIOReturnSuccess
    }

    private func report(featureIndex: UInt8, function: UInt8, params: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: Self.reportSize)
        report[0] = Self.longReportID
        report[1] = deviceIndex
        report[2] = featureIndex
        report[3] = (function << 4) | 0x01
        for (offset, value) in params.prefix(16).enumerated() { report[4 + offset] = value }
        return report
    }

    @discardableResult
    private func send(featureIndex: UInt8, function: UInt8, params: [UInt8] = []) -> Bool {
        let bytes = report(featureIndex: featureIndex, function: function, params: params)
        if let externalSend { return externalSend(bytes) }
        guard let device else { return false }
        let result = IOHIDDeviceSetReport(
            device, kIOHIDReportTypeOutput, CFIndex(Self.longReportID), bytes, bytes.count
        )
        return result == kIOReturnSuccess
    }

    private func handleDivertedButtons(_ report: [UInt8]) {
        publishButtonState(LogitechHIDPPProtocol.activeButtons(
            in: report,
            ownedCIDs: divertedCIDs
        ))
    }

    private func publishButtonState(_ now: Set<Int>) {
        let changes = buttonState.update(now)
        if !changes.pressed.isEmpty || !changes.released.isEmpty {
            Self.log.notice("\(self.name, privacy: .public) activeButtons=\(now.sorted(), privacy: .public)")
        }
        for button in changes.pressed.sorted() { onButton(button, true) }
        for button in changes.released.sorted() { onButton(button, false) }
    }

    private func releaseAllButtons() {
        publishButtonState([])
    }

    private func cancelAllButtons() {
        let released = buttonState.update([]).released
        for button in released.sorted() {
            if let onCancelButton { onCancelButton(button) }
            else { onButton(button, false) }
        }
    }

    private func armTimeout(label: String) {
        timeout?.cancel()
        // A receiver request may wait behind another slot/receiver-register command. Its
        // physical transport owns the timeout from actual transmission, not enqueue time.
        guard externalSend == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stage != .ready, !self.stopped else { return }
            self.stage = .failed
            Self.log.error("\(self.name, privacy: .public) timeout during \(label, privacy: .public)")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func armDPITimeout(label: String) {
        dpiTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dpiStage != .idle, !self.stopped else { return }
            self.finishDPIRequest(error: "timeout during \(label)")
        }
        dpiTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
