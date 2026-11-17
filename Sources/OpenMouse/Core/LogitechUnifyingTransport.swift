import Foundation
import IOKit
import IOKit.hid
import os

/// Owns one vendor HID interface, not one peripheral. USB replies and request timeouts run on
/// a private queue, so receiver latency cannot occupy the event-tap run loop. In particular,
/// shutdown can finish restoring a control while the main thread is waiting to exit.
final class LogitechUnifyingTransport {
    typealias Reply = ([UInt8]?) -> Void
    private static let log = Logger(subsystem: "com.openmouse.OpenMouse", category: "hidpp")
    private static let requestTimeout: TimeInterval = 1.5

    let id = UUID()
    private let device: IOHIDDevice?
    private let submitOverride: HIDAsyncReport.Submit?
    private let queue = DispatchQueue(label: "com.openmouse.unifying.transport", qos: .userInitiated)
    private let accepting = Locked(false)
    private let stopRequested = Locked(false)
    private let finished = Locked(false)
    private let stoppedGroup = DispatchGroup()
    private let onNotification: ([UInt8]) -> Void
    private let onStopped: () -> Void
    private let inputBuffer: UnsafeMutablePointer<UInt8>

    // These fields belong exclusively to queue. The self-retain is released only in the HID
    // cancellation handler, after Apple's last callback has finished using its raw context.
    private var keepAlive: LogitechUnifyingTransport?
    private var opened = false
    private var activated = false
    private var cancelling = false
    private var transactions = LogitechHIDPPTransactionQueue()
    private var slots = LogitechUnifyingSlotState()
    private var controlFeatures: [UInt8: UInt8] = [:]
    private var replies: [UUID: Reply] = [:]
    private var restorationReplies: [UUID: Reply] = [:]
    private var restorationPlans: [UUID: (slot: UInt8, lease: UUID)] = [:]
    private var requestTimeout: DispatchWorkItem?
    private var shutdownDeadline: DispatchWorkItem?

    init(device: IOHIDDevice? = nil, submitForSelfCheck: HIDAsyncReport.Submit? = nil,
         onNotification: @escaping ([UInt8]) -> Void, onStopped: @escaping () -> Void) {
        precondition(device != nil || submitForSelfCheck != nil)
        self.device = device
        submitOverride = submitForSelfCheck
        self.onNotification = onNotification
        self.onStopped = onStopped
        inputBuffer = .allocate(capacity: 64)
        inputBuffer.initialize(repeating: 0, count: 64)
        stoppedGroup.enter()
    }

    deinit {
        inputBuffer.deinitialize(count: 64)
        inputBuffer.deallocate()
    }

    var isStopped: Bool { finished.value }

    func start(completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            self.keepAlive = self
            guard !self.stopRequested.value else {
                self.finishStopped()
                DispatchQueue.main.async { completion(false) }
                return
            }
            guard let device = self.device else {
                self.accepting.value = !self.stopRequested.value
                DispatchQueue.main.async { completion(!self.stopRequested.value) }
                return
            }
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                Self.log.error("Unifying vendor interface open failed result=0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
                self.finishStopped()
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.opened = true
            IOHIDDeviceSetDispatchQueue(device, self.queue)
            IOHIDDeviceRegisterInputReportCallback(
                device, self.inputBuffer, 64, Self.inputReport,
                Unmanaged.passUnretained(self).toOpaque()
            )
            IOHIDDeviceSetCancelHandler(device) { [weak self] in self?.finishStopped() }
            IOHIDDeviceActivate(device)
            self.activated = true
            self.accepting.value = !self.stopRequested.value
            DispatchQueue.main.async { completion(!self.stopRequested.value) }
        }
    }

    @discardableResult
    func send(_ report: [UInt8], reply: @escaping Reply) -> Bool {
        guard accepting.value, LogitechUnifyingProtocol.isValidReport(report) else { return false }
        queue.async {
            guard self.accepting.value, !self.cancelling,
                  report[1] == 0xFF || self.slots.accepts(slot: report[1]),
                  let id = self.transactions.enqueue(report) else {
                DispatchQueue.main.async { reply(nil) }
                return
            }
            self.replies[id] = reply
            self.pump()
        }
        return true
    }

    /// Drives the real queue/matching/restoration code without opening an IOKit device.
    func receiveForSelfCheck(_ report: [UInt8]) {
        precondition(submitOverride != nil)
        queue.async { self.receive(report) }
    }

    func cancelRequests(slot: UInt8) {
        queue.async { self.cancelQueuedRequests(slot: slot) }
    }

    /// Do not interrupt an already transmitted command and immediately send another one: the
    /// receiver may still be busy. Drop stale callbacks/queued commands and let its reply or
    /// bounded timeout free the wire before the next command starts.
    private func cancelQueuedRequests(slot: UInt8) {
        var ids = transactions.cancel(slot: slot, includingActive: false)
        if let active = transactions.active, active.original[1] == slot { ids.append(active.id) }
        for id in ids {
            replies.removeValue(forKey: id)
            restorationReplies.removeValue(forKey: id)
            restorationPlans.removeValue(forKey: id)
        }
    }

    /// A protocol failure/recapture can discard the logical mouse while the physical device
    /// remains diverted. Track that obligation here and resolve the current feature index
    /// before clearing it; an old cached index is not a safe shutdown address.
    func restoreModifiedThumb() {
        queue.async {
            guard !self.cancelling, !self.finished.value else { return }
            for slot in self.slots.restorationSlots { self.requestRestoration(slot: slot) }
            self.pump()
        }
    }

    func stop(restoreControls: Bool = true) {
        guard !stopRequested.value else { return }
        stopRequested.value = true
        accepting.value = false
        queue.async { [self] in
            guard !self.finished.value, !self.cancelling else { return }
            for id in self.transactions.cancel(includingActive: false) {
                self.replies.removeValue(forKey: id)
                self.restorationReplies.removeValue(forKey: id)
                self.restorationPlans.removeValue(forKey: id)
            }
            if restoreControls {
                for slot in self.slots.restorationSlots { self.requestRestoration(slot: slot) }
            }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, !self.finished.value, !self.cancelling else { return }
                Self.log.error("Unifying shutdown deadline reached; closing vendor interface")
                self.closeInterface()
            }
            self.shutdownDeadline = deadline
            self.queue.asyncAfter(deadline: .now() + LogitechUnifyingProtocol.shutdownTimeout, execute: deadline)
            self.pump()
        }
    }

    private func requestRestoration(slot: UInt8) {
        guard let lease = slots.lease(slot: slot),
              !restorationPlans.values.contains(where: { $0.slot == slot && $0.lease == lease }),
              let root = LogitechUnifyingProtocol.rootControlsRequest(slot: slot) else { return }
        enqueueRestoration(root, slot: slot, lease: lease) { [weak self] response in
            guard let self, self.slots.lease(slot: slot) == lease else { return }
            guard let response, LogitechUnifyingProtocol.errorCode(in: response) == nil,
                  let restore = LogitechUnifyingProtocol.restoreThumbRequest(slot: slot, feature: response[4]) else {
                Self.log.error("Unifying thumb restore could not resolve REPROG_CONTROLS_V4 slot=\(slot)")
                return
            }
            self.enqueueRestoration(restore, slot: slot, lease: lease) { response in
                if response == nil || response.flatMap(LogitechUnifyingProtocol.errorCode(in:)) != nil {
                    Self.log.error("Unifying thumb restore was not acknowledged slot=\(slot)")
                }
            }
        }
    }

    private func enqueueRestoration(_ report: [UInt8], slot: UInt8, lease: UUID, reply: @escaping Reply) {
        guard let id = transactions.enqueue(report) else {
            Self.log.error("Unifying restoration queue is full slot=\(slot)")
            return
        }
        restorationPlans[id] = (slot, lease)
        restorationReplies[id] = reply
    }

    private func deliver(_ id: UUID, reply: [UInt8]?) {
        restorationPlans.removeValue(forKey: id)
        // Restoration never needs the main queue. Otherwise applicationWillTerminate's
        // bounded flush would deadlock waiting for a callback on the thread it is blocking.
        if let callback = restorationReplies.removeValue(forKey: id) { callback(reply) }
        else if let callback = replies.removeValue(forKey: id) { DispatchQueue.main.async { callback(reply) } }
    }

    func waitUntilStopped(deadline: DispatchTime) -> Bool {
        stoppedGroup.wait(timeout: deadline) == .success
    }

    private func pump() {
        guard !cancelling else { return }
        guard let request = transactions.beginNext() else {
            if stopRequested.value, transactions.isEmpty { closeInterface() }
            return
        }
        let id = request.id
        let leaseMatches = restorationPlans[id].map { slots.lease(slot: $0.slot) == $0.lease } ?? true
        guard request.original[1] == 0xFF || slots.accepts(slot: request.original[1]),
              leaseMatches else {
            _ = transactions.failActive()
            deliver(id, reply: nil)
            pump()
            return
        }
        slots.submitted(request.original, id: id)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.transactions.active?.id == id else { return }
            Self.log.error("Unifying request timeout slot=\(request.wire[1]) command=0x\(String(request.wire[2], radix: 16), privacy: .public)")
            self.failActive()
        }
        requestTimeout = timeout
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: timeout)
        let result = HIDAsyncReport.send(request.wire, submit: { bytes, count, callback, context in
            if let submitOverride { return submitOverride(bytes, count, callback, context) }
            guard let device else { return kIOReturnNoDevice }
            return IOHIDDeviceSetReportWithCallback(
                device, kIOHIDReportTypeOutput, CFIndex(request.wire[0]),
                bytes, count, 1_000, callback, context
            )
        }, completion: { [weak self] result in
            guard result != kIOReturnSuccess else { return }
            // Apple's output callback and input replies are both delivered on queue. Still
            // defer failure handling, so a synchronous abort cannot reenter cancellation.
            self?.queue.async { [weak self] in
                guard let self, self.transactions.active?.id == id, !self.cancelling else { return }
                Self.log.error("Unifying async output failed result=0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
                self.failActive()
            }
        })
        if result != kIOReturnSuccess { failActive() }
    }

    private func failActive() {
        requestTimeout?.cancel()
        requestTimeout = nil
        if let request = transactions.failActive() { deliver(request.id, reply: nil) }
        pump()
    }

    private static let inputReport: IOHIDReportCallback = { context, result, _, _, reportID, report, length in
        guard let context, result == kIOReturnSuccess, length >= 0, length <= 64 else { return }
        let transport = Unmanaged<LogitechUnifyingTransport>.fromOpaque(context).takeUnretainedValue()
        var bytes = Array(UnsafeBufferPointer(start: report, count: length))
        let id = UInt8(truncatingIfNeeded: reportID)
        if bytes.first != id, id != 0 { bytes.insert(id, at: 0) }
        transport.receive(bytes)
    }

    private func receive(_ report: [UInt8]) {
        guard !cancelling, LogitechUnifyingProtocol.isValidReport(report) else { return }
        if let notification = LogitechUnifyingProtocol.linkNotification(in: report) {
            // Reject stale peripheral writes on this queue, even if the main thread is busy
            // or waiting for shutdown. Never restore an old mouse's CID to a new keyboard.
            slots.observe(notification)
            switch notification {
            case let .disconnected(slot):
                controlFeatures.removeValue(forKey: slot)
                cancelQueuedRequests(slot: slot)
            case let .connected(device, online):
                if !device.isM720 || !online {
                    controlFeatures.removeValue(forKey: device.slot)
                    cancelQueuedRequests(slot: device.slot)
                }
            }
            if !stopRequested.value { DispatchQueue.main.async { self.onNotification(report) } }
            return
        }
        if let completed = transactions.complete(with: report) {
            requestTimeout?.cancel()
            requestTimeout = nil
            if let device = LogitechUnifyingProtocol.pairedDevice(in: completed.reply) {
                slots.observe(device)
                if !device.isM720 {
                    controlFeatures.removeValue(forKey: device.slot)
                    cancelQueuedRequests(slot: device.slot)
                }
            }
            let original = completed.request.original
            if original[1] != 0xFF, original[2] == 0, original[4] == 0x1B, original[5] == 4,
               LogitechUnifyingProtocol.errorCode(in: completed.reply) == nil {
                let feature = completed.reply[4]
                if feature > 0, feature < 0x80 { controlFeatures[original[1]] = feature }
                else { controlFeatures.removeValue(forKey: original[1]) }
            }
            slots.completed(completed.request.original, reply: completed.reply)
            deliver(completed.request.id, reply: completed.reply)
            pump()
            return
        }
        // Unsolicited HID++ control state, not generic keyboard reports or another client's
        // command replies. The receiver session will additionally verify the selected slot.
        if !stopRequested.value, slots.accepts(slot: report[1]),
           controlFeatures[report[1]] == report[2], report[3] == 0 {
            // Battery/wheel/vendor traffic must not wake the tap's main run loop. Only the
            // discovered REPROG_CONTROLS_V4 physical-state notification is useful here.
            DispatchQueue.main.async { self.onNotification(report) }
        }
    }

    private func closeInterface() {
        guard !cancelling else { return }
        cancelling = true
        accepting.value = false
        requestTimeout?.cancel()
        shutdownDeadline?.cancel()
        requestTimeout = nil
        shutdownDeadline = nil
        _ = transactions.cancel()
        replies.removeAll()
        restorationReplies.removeAll()
        restorationPlans.removeAll()
        if !slots.restorationSlots.isEmpty {
            Self.log.error("Unifying closed with an unacknowledged thumb restoration")
        }
        if activated, let device { IOHIDDeviceCancel(device) }
        else { finishStopped() }
    }

    private func finishStopped() {
        guard !finished.value else { return }
        if opened, let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            opened = false
        }
        accepting.value = false
        finished.value = true
        stoppedGroup.leave()
        DispatchQueue.main.async { self.onStopped() }
        keepAlive = nil
    }
}
