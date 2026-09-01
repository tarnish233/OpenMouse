import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import os

/// Pure HID++ facts kept separate from IOKit lifecycle so regressions can be asserted without
/// opening a real device. Values are protocol identifiers, not copied implementation code.
enum LogitechHIDPPProtocol {
    static let adjustableDPIFeature: UInt16 = 0x2201

    /// `CGEvent` numbers used for controls that only arrive through HID++. Keep these in the
    /// normal extra-button range so the existing binding model can treat them exactly like a
    /// generic sixth mouse button.
    static let dpiSwitchButton = 5

    static let cidToButton: [UInt16: Int] = [
        0x0052: 2, // middle
        0x0053: 3, // back
        0x0056: 4, // forward
        0x00C3: 4, // Logitech Gesture
        0x00D7: 4, // Logitech Virtual Gesture
        0x00FD: dpiSwitchButton // DPI Switch
    ]

    /// Controls that do not emit a usable native `CGEvent` before they have been diverted. They
    /// must be owned temporarily while the recorder is open, otherwise there is no first press
    /// from which a user can create a binding.
    static let captureOnlyButtons: Set<Int> = [dpiSwitchButton]

    static func desiredButtons(configured: Set<Int>, capturing: Bool) -> Set<Int> {
        guard capturing else { return configured }
        return configured.union(captureOnlyButtons)
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

    private static let vendorID = 0x046D
    private static let log = Logger(subsystem: "com.openmouse.OpenMouse", category: "hidpp")

    private let onButton: ButtonHandler
    private let onOwnedButtonsChanged: (Set<Int>) -> Void
    private var onDPIChanged: DPIHandler?
    private var currentDPI: Int?
    private var manager: IOHIDManager?
    private var sessions: [IOHIDDevice: LogitechHIDPPDeviceSession] = [:]
    private var desiredButtons: Set<Int> = []
    private(set) var isRunning = false

    init(
        onButton: @escaping ButtonHandler,
        onOwnedButtonsChanged: @escaping (Set<Int>) -> Void
    ) {
        self.onButton = onButton
        self.onOwnedButtonsChanged = onOwnedButtonsChanged
    }

    func start() {
        guard !isRunning else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey as String: Self.vendorID] as CFDictionary
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
            self.manager = nil
            return
        }
        isRunning = true
        Self.log.notice("manager started")
    }

    func stop() {
        guard isRunning || manager != nil else { return }
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
        guard transport.lowercased().contains("bluetooth"),
              usagePage == 0x0001, usage == 0x0002 else { return }

        let session = LogitechHIDPPDeviceSession(
            device: device,
            name: name.isEmpty ? "Logitech mouse" : name,
            productID: propertyInt(device, kIOHIDProductIDKey),
            onButton: onButton,
            onOwnershipChanged: { [weak self] in self?.publishOwnedButtons() },
            onDPIChanged: { [weak self] dpi in self?.publishDPI(dpi) }
        )
        sessions[device] = session
        session.updateDesiredButtons(desiredButtons)
        session.start()
    }

    private func detach(_ device: IOHIDDevice) {
        guard let session = sessions.removeValue(forKey: device) else { return }
        session.stop()
        publishOwnedButtons()
        if sessions.isEmpty { publishDPI(nil) }
    }

    private func publishDPI(_ dpi: Int?) {
        guard currentDPI != dpi else { return }
        currentDPI = dpi
        onDPIChanged?(dpi)
    }

    private func publishOwnedButtons() {
        let buttons = sessions.values.reduce(into: Set<Int>()) { result, session in
            result.formUnion(session.ownedButtons)
        }
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
private final class LogitechHIDPPDeviceSession {
    private struct Control {
        let cid: UInt16
        let divertable: Bool
    }

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
    private static let deviceIndex: UInt8 = 0xFF
    private static let reprogControlsV4: UInt16 = 0x1B04
    private static let reportSize = 20

    private let device: IOHIDDevice
    private let name: String
    private let productID: Int
    private let onButton: LogitechHIDPPManager.ButtonHandler
    private let onOwnershipChanged: () -> Void
    private let onDPIChanged: (Int) -> Void
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var opened = false
    private var stopped = false
    private var stage: ProtocolStage = .idle
    private var reprogFeatureIndex: UInt8?
    private var controls: [Control] = []
    private var desiredButtons: Set<Int> = []
    private var divertedCIDs: Set<UInt16> = []
    private var activeButtons: Set<Int> = []
    private var timeout: DispatchWorkItem?
    private var dpiFeatureIndex: UInt8?
    private var dpiLevels: LogitechDPILevels?
    private var dpiStage: DPIToggleStage = .idle
    private var dpiTimeout: DispatchWorkItem?

    var ownedButtons: Set<Int> {
        Set(divertedCIDs.compactMap { LogitechHIDPPProtocol.cidToButton[$0] })
    }

    init(
        device: IOHIDDevice,
        name: String,
        productID: Int,
        onButton: @escaping LogitechHIDPPManager.ButtonHandler,
        onOwnershipChanged: @escaping () -> Void,
        onDPIChanged: @escaping (Int) -> Void
    ) {
        self.device = device
        self.name = name
        self.productID = productID
        self.onButton = onButton
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
            device,
            buffer,
            64,
            Self.inputReport,
            Unmanaged.passUnretained(self).toOpaque()
        )

        Self.log.notice("device connected name=\(self.name, privacy: .public) pid=0x\(String(self.productID, radix: 16), privacy: .public)")
        stage = .feature
        armTimeout(label: "feature discovery")
        _ = send(featureIndex: 0x00, function: 0, params: [0x1B, 0x04])
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timeout?.cancel()
        timeout = nil
        dpiTimeout?.cancel()
        dpiTimeout = nil
        dpiStage = .idle
        dpiLevels = nil
        releaseAllButtons()
        if let feature = reprogFeatureIndex {
            for cid in divertedCIDs.sorted() {
                _ = setReporting(featureIndex: feature, cid: cid, divert: false)
            }
        }
        divertedCIDs.removeAll()
        onOwnershipChanged()
        if opened {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            opened = false
        }
        Self.log.notice("device stopped name=\(self.name, privacy: .public)")
    }

    func updateDesiredButtons(_ buttons: Set<Int>) {
        desiredButtons = buttons
        if stage == .ready { applyDesiredDiverts() }
    }

    func refreshDPI() {
        guard stage == .ready, dpiStage == .idle else { return }
        beginDPIRequest(levels: nil)
    }

    func toggleDPI(_ levels: LogitechDPILevels) {
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
        dpiLevels = levels
        if let feature = dpiFeatureIndex {
            requestCurrentDPI(featureIndex: feature)
        } else {
            dpiStage = .feature
            armDPITimeout(label: "DPI feature discovery")
            guard send(
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
        guard let context else { return }
        let session = Unmanaged<LogitechHIDPPDeviceSession>
            .fromOpaque(context)
            .takeUnretainedValue()
        var bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
        let id = UInt8(truncatingIfNeeded: reportID)
        if bytes.first != id, id != 0 { bytes.insert(id, at: 0) }
        MainActor.assumeIsolated { session.receive(bytes) }
    }

    private func receive(_ report: [UInt8]) {
        guard !stopped, report.count >= 7,
              report[0] == 0x10 || report[0] == Self.longReportID,
              report[1] == Self.deviceIndex else { return }

        let feature = report[2]
        let function = report[3] >> 4
        let softwareID = report[3] & 0x0F

        if feature == 0xFF {
            if dpiStage != .idle {
                let error = report.count > 6 ? report[6] : 0
                finishDPIRequest(error: "HID++ error code=0x\(String(error, radix: 16))")
                return
            }
            timeout?.cancel()
            stage = .failed
            let originalFeature = report.count > 3 ? report[3] : 0
            let error = report.count > 6 ? report[6] : 0
            Self.log.error("\(self.name, privacy: .public) HID++ error feature=0x\(String(originalFeature, radix: 16), privacy: .public) code=0x\(String(error, radix: 16), privacy: .public)")
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
            controls.append(Control(cid: cid, divertable: divertable))
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
        let desiredCIDs = Set(controls.compactMap { control -> UInt16? in
            guard control.divertable,
                  let button = LogitechHIDPPProtocol.cidToButton[control.cid],
                  desiredButtons.contains(button) else { return nil }
            return control.cid
        })

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
            guard send(
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
        guard send(featureIndex: featureIndex, function: 2, params: [0x00]) else {
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
        resetDPIRequest()
        Self.log.error("\(self.name, privacy: .public) DPI request failed: \(error, privacy: .public)")
    }

    private func resetDPIRequest() {
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

    @discardableResult
    private func send(featureIndex: UInt8, function: UInt8, params: [UInt8] = []) -> Bool {
        var report = [UInt8](repeating: 0, count: Self.reportSize)
        report[0] = Self.longReportID
        report[1] = Self.deviceIndex
        report[2] = featureIndex
        report[3] = (function << 4) | 0x01
        for (offset, value) in params.prefix(16).enumerated() { report[4 + offset] = value }
        let result = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeOutput,
            CFIndex(Self.longReportID),
            report,
            report.count
        )
        return result == kIOReturnSuccess
    }

    private func handleDivertedButtons(_ report: [UInt8]) {
        let now = LogitechHIDPPProtocol.activeButtons(
            in: report,
            ownedCIDs: divertedCIDs
        )
        let pressed = now.subtracting(activeButtons)
        let released = activeButtons.subtracting(now)
        activeButtons = now
        if !pressed.isEmpty || !released.isEmpty {
            Self.log.notice("\(self.name, privacy: .public) activeButtons=\(now.sorted(), privacy: .public)")
        }
        for button in pressed.sorted() { onButton(button, true) }
        for button in released.sorted() { onButton(button, false) }
    }

    private func releaseAllButtons() {
        let held = activeButtons
        activeButtons.removeAll()
        for button in held.sorted() { onButton(button, false) }
    }

    private func armTimeout(label: String) {
        timeout?.cancel()
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
