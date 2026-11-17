import Foundation
import IOKit.hid
import os

/// Deliberately narrow receiver support: one M720 thumb control per known Unifying receiver.
/// Receiver registers identify slots first; no HID++ feature discovery is sent to keyboards,
/// unknown peripherals, or arbitrary slots. Ordinary mouse buttons retain the CGEvent path.
@MainActor
final class LogitechUnifyingReceiver {
    private static let log = Logger(subsystem: "com.openmouse.OpenMouse", category: "hidpp")
    private static let retryDelays: [TimeInterval] = [0.4, 1.2, 3]

    let id: UUID
    private(set) var transport: LogitechUnifyingTransport!
    private let onButton: LogitechHIDPPManager.ButtonHandler
    private let onCancelButton: (Int) -> Void
    private let onOwnershipChanged: () -> Void
    private let isSelfCheck: Bool
    private var desiredButtons: Set<Int> = []
    private var selected: LogitechUnifyingProtocol.PairedDevice?
    private var mouse: LogitechHIDPPDeviceSession?
    private var mouseToken = UUID()
    private var scanToken = UUID()
    private var retry: DispatchWorkItem?
    private var retryCount = 0
    private var stopped = false

    var ownedButtons: Set<Int> { mouse?.ownedButtons ?? [] }

    init(device: IOHIDDevice? = nil, submitForSelfCheck: HIDAsyncReport.Submit? = nil,
         onButton: @escaping LogitechHIDPPManager.ButtonHandler,
         onCancelButton: @escaping (Int) -> Void, onOwnershipChanged: @escaping () -> Void,
         onStopped: @escaping (UUID) -> Void) {
        let id = UUID()
        self.id = id
        self.onButton = onButton
        self.onCancelButton = onCancelButton
        self.onOwnershipChanged = onOwnershipChanged
        isSelfCheck = submitForSelfCheck != nil
        transport = LogitechUnifyingTransport(device: device, submitForSelfCheck: submitForSelfCheck,
                                              onNotification: { [weak self] report in
            MainActor.assumeIsolated { self?.receiveNotification(report) }
        }, onStopped: { onStopped(id) })
    }

    func start() {
        transport.start { [weak self] opened in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                guard opened else { self.stop(restoreControls: false); return }
                if !self.isSelfCheck { Self.log.notice("Unifying vendor interface opened; discovering M720 slots") }
                self.configureNotifications()
            }
        }
    }

    @discardableResult
    func stop(restoreControls: Bool = true) -> LogitechUnifyingTransport {
        guard !stopped else { return transport }
        stopped = true
        retry?.cancel()
        retry = nil
        scanToken = UUID()
        mouseToken = UUID()
        mouse?.stop(restoreControls: false, cancelHeld: true)
        mouse = nil
        selected = nil
        transport.stop(restoreControls: restoreControls)
        onOwnershipChanged()
        return transport
    }

    func updateDesiredButtons(_ buttons: Set<Int>) {
        let shouldRetry = buttons.contains(LogitechHIDPPProtocol.m720ThumbButton)
            && !desiredButtons.contains(LogitechHIDPPProtocol.m720ThumbButton)
        let shouldRestore = !buttons.contains(LogitechHIDPPProtocol.m720ThumbButton)
            && desiredButtons.contains(LogitechHIDPPProtocol.m720ThumbButton)
        desiredButtons = buttons
        mouse?.updateDesiredButtons(buttons)
        if shouldRestore { transport.restoreModifiedThumb() }
        if shouldRetry, mouse == nil, !stopped { rescan() }
    }

    func prepareForCapture() {
        guard mouse == nil || mouse?.needsRecovery == true else { return }
        rescan()
    }

    /// Wake/capture can start a new finite discovery window. Re-read identity rather than
    /// reusing a slot after sleep/re-pairing; its new occupant could be a keyboard.
    func rescan() {
        guard !stopped else { return }
        forgetSelection()
        requestConnectionsAndScan()
    }

    private func configureNotifications() {
        _ = transport.send(LogitechUnifyingProtocol.readNotifications) { [weak self] response in
            guard let self, !self.stopped else { return }
            guard let response, response[2] == 0x81, response[3] == 0,
                  let enable = LogitechUnifyingProtocol.enableWirelessNotifications(
                    preserving: Array(response[4...6])
                  ) else {
                Self.log.error("Unifying notification flags unavailable; initial slot scan will still run")
                self.requestConnectionsAndScan()
                return
            }
            if response[5] & 1 != 0 { self.requestConnectionsAndScan(); return }
            _ = self.transport.send(enable) { [weak self] response in
                guard let self, !self.stopped else { return }
                if response == nil || response.flatMap(LogitechUnifyingProtocol.errorCode(in:)) != nil {
                    Self.log.error("Unifying wireless notifications could not be enabled")
                }
                self.requestConnectionsAndScan()
            }
        }
    }

    private func requestConnectionsAndScan() {
        guard !stopped else { return }
        let token = UUID()
        scanToken = token
        _ = transport.send(LogitechUnifyingProtocol.requestConnections) { [weak self] _ in
            guard let self, !self.stopped, self.scanToken == token else { return }
            self.scan(slot: 1, token: token)
        }
    }

    private func scan(slot: UInt8, token: UUID) {
        guard !stopped, scanToken == token, selected == nil,
              let request = LogitechUnifyingProtocol.pairingRequest(slot: slot) else { return }
        _ = transport.send(request) { [weak self] response in
            guard let self, !self.stopped, self.scanToken == token, self.selected == nil else { return }
            if let response, let device = LogitechUnifyingProtocol.pairedDevice(in: response),
               device.slot == slot, device.isM720 {
                self.adopt(device)
            } else if slot < 6 {
                self.scan(slot: slot + 1, token: token)
            } else {
                if !self.isSelfCheck { Self.log.notice("Unifying scan complete: no paired M720 (mouse WPID 0x405e)") }
            }
        }
    }

    private func adopt(_ device: LogitechUnifyingProtocol.PairedDevice) {
        guard !stopped, device.isM720 else { return }
        // Do not silently take a second mouse on the same receiver. A new scan can select
        // another M720 after the selected device leaves; simultaneous multi-M720 is out of scope.
        guard selected == nil || selected == device else { return }
        selected = device
        retryCount = 0
        retry?.cancel()
        retry = nil
        // Resolve an outstanding old diversion before a new logical session is ready. The
        // transport's lease generation prevents this restoration undoing a later new divert.
        transport.restoreModifiedThumb()
        beginMouse(device)
    }

    private func beginMouse(_ device: LogitechUnifyingProtocol.PairedDevice) {
        guard !stopped, selected == device, device.isM720, mouse == nil else { return }
        let token = UUID()
        mouseToken = token
        let session = LogitechHIDPPDeviceSession(
            name: "\(isSelfCheck ? "self-check M720" : "M720") Unifying slot \(device.slot)",
            productID: Int(device.wirelessProductID),
            deviceIndex: device.slot, allowedButtons: [LogitechHIDPPProtocol.m720ThumbButton],
            supportsDPI: false, sendReport: { [weak self] report in
                guard let self, !self.stopped, self.mouseToken == token,
                      self.selected == device else { return false }
                return self.transport.send(report) { [weak self] response in
                    guard let self, !self.stopped, self.mouseToken == token, self.selected == device else { return }
                    guard let response else { self.recoverMouse(device); return }
                    self.mouse?.receive(response)
                    if self.mouse?.needsRecovery == true { self.recoverMouse(device) }
                }
            }, onButton: onButton, onCancelButton: onCancelButton,
            onOwnershipChanged: onOwnershipChanged, onDPIChanged: { _ in }
        )
        mouse = session
        session.updateDesiredButtons(desiredButtons)
        if !isSelfCheck { Self.log.notice("Unifying M720 identified slot=\(device.slot) wpid=0x405e; thumb-only support") }
        session.start()
        if session.needsRecovery { recoverMouse(device) }
    }

    private func recoverMouse(_ device: LogitechUnifyingProtocol.PairedDevice) {
        guard !stopped, selected == device else { return }
        mouseToken = UUID()
        mouse?.stop(restoreControls: false, cancelHeld: true)
        mouse = nil
        transport.cancelRequests(slot: device.slot)
        transport.restoreModifiedThumb()
        onOwnershipChanged()
        guard retry == nil, retryCount < Self.retryDelays.count else {
            if retry == nil { Self.log.error("Unifying M720 discovery failed; waiting for reconnect/wake/new capture") }
            return
        }
        let delay = Self.retryDelays[retryCount]
        retryCount += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.selected == device,
                  let request = LogitechUnifyingProtocol.pairingRequest(slot: device.slot) else { return }
            self.retry = nil
            // Every retry revalidates slot identity. Do not keep probing an old mouse slot
            // which has since been re-paired to a keyboard while notifications were unavailable.
            _ = self.transport.send(request) { [weak self] response in
                guard let self, !self.stopped, self.selected == device else { return }
                guard let response, let current = LogitechUnifyingProtocol.pairedDevice(in: response),
                      current == device, current.isM720 else { self.forgetSelection(); return }
                self.beginMouse(current)
            }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func receiveNotification(_ report: [UInt8]) {
        guard !stopped else { return }
        if let notification = LogitechUnifyingProtocol.linkNotification(in: report) {
            switch notification {
            case let .disconnected(slot):
                if selected?.slot == slot { forgetSelection() }
            case let .connected(device, online):
                if selected?.slot == device.slot, !device.isM720 || !online { forgetSelection() }
                else if device.isM720, online, mouse == nil { adopt(device) }
            }
            return
        }
        guard let selected, report[1] == selected.slot else { return }
        mouse?.receive(report)
    }

    private func forgetSelection() {
        retry?.cancel()
        retry = nil
        retryCount = 0
        mouseToken = UUID()
        if let selected { transport.cancelRequests(slot: selected.slot) }
        mouse?.stop(restoreControls: false, cancelHeld: true)
        mouse = nil
        selected = nil
        onOwnershipChanged()
    }
}
