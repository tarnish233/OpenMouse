import Foundation
import IOKit.hid

/// Receiver identity and wire facts, not copied driver implementation. See
/// docs/m720-thumb-button.md for Logitech's public HID++ 1.0 specification and WPID evidence.
enum LogitechUnifyingProtocol {
    static let receiverProductIDs: Set<Int> = [0xC52B, 0xC532]
    static let m720WirelessProductID: UInt16 = 0x405E
    static let slots: ClosedRange<UInt8> = 1...6
    static let receiverIndex: UInt8 = 0xFF
    static let shutdownTimeout: TimeInterval = 2
    static let exitFlushTimeout: TimeInterval = 3

    struct Usage: Hashable {
        let page: Int
        let usage: Int
    }

    static func usages(from property: Any?) -> Set<Usage> {
        guard let pairs = property as? [[String: Any]] else { return [] }
        return Set(pairs.compactMap { pair in
            guard let page = pair[kIOHIDDeviceUsagePageKey] as? Int,
                  let usage = pair[kIOHIDDeviceUsageKey] as? Int else { return nil }
            return Usage(page: page, usage: usage)
        })
    }

    static func acceptsInterface(vendorID: Int, productID: Int, transport: String, usages: Set<Usage>) -> Bool {
        // Opening the generic keyboard/mouse interface would intercept unrelated real input.
        // Require the short AND long vendor collections of a known Unifying receiver; Bolt,
        // Nano, Lightspeed and arbitrary Logitech USB endpoints are deliberately out of scope.
        vendorID == LogitechHIDPPDevicePolicy.vendorID
            && receiverProductIDs.contains(productID)
            && transport.lowercased().contains("usb")
            && usages.contains(Usage(page: 0xFF00, usage: 1))
            && usages.contains(Usage(page: 0xFF00, usage: 2))
            && !usages.contains(Usage(page: 1, usage: 6))
            && !usages.contains(Usage(page: 1, usage: 2))
    }

    struct PairedDevice: Equatable {
        let slot: UInt8
        let wirelessProductID: UInt16
        let kind: UInt8
        var isM720: Bool { kind == 2 && wirelessProductID == m720WirelessProductID }
    }

    enum LinkNotification: Equatable {
        case connected(PairedDevice, online: Bool)
        case disconnected(UInt8)
    }

    static func isValidReport(_ report: [UInt8]) -> Bool {
        guard let id = report.first else { return false }
        return (id == 0x10 && report.count >= 7) || (id == 0x11 && report.count >= 20)
    }

    static let readNotifications: [UInt8] = [0x10, 0xFF, 0x81, 0x00, 0, 0, 0]
    static let requestConnections: [UInt8] = [0x10, 0xFF, 0x80, 0x02, 0x02, 0, 0]

    static func enableWirelessNotifications(preserving flags: [UInt8]) -> [UInt8]? {
        guard flags.count == 3 else { return nil }
        // This receiver-wide bit is shared with other clients. Preserve every other flag and
        // never clear the wireless bit on exit: that could disable another client's reporting.
        return [0x10, 0xFF, 0x80, 0x00, flags[0], flags[1] | 0x01, flags[2]]
    }

    static func pairingRequest(slot: UInt8) -> [UInt8]? {
        guard slots.contains(slot) else { return nil }
        // GET_LONG_REGISTER, not pairing/unpairing or a probe of the peripheral's keyboard.
        return [0x10, 0xFF, 0x83, 0xB5, 0x20 + slot - 1, 0, 0]
    }

    static func pairedDevice(in report: [UInt8]) -> PairedDevice? {
        guard isValidReport(report), report[0] == 0x11, report[1] == receiverIndex,
              report[2] == 0x83, report[3] == 0xB5,
              (0x20...0x25).contains(report[4]) else { return nil }
        // Pairing register 0x2B5 uses big-endian WPID at r3/r4; the device kind is r7.
        return PairedDevice(slot: report[4] - 0x20 + 1,
                            wirelessProductID: UInt16(report[7]) << 8 | UInt16(report[8]),
                            kind: report[11] & 0x0F)
    }

    static func linkNotification(in report: [UInt8]) -> LinkNotification? {
        guard isValidReport(report), report[0] == 0x10, slots.contains(report[1]) else { return nil }
        if report[2] == 0x40 { return .disconnected(report[1]) }
        guard report[2] == 0x41, report[3] & 0x07 == 0x04 else { return nil }
        // Connection notifications have the opposite WPID byte order to the pairing register.
        let device = PairedDevice(slot: report[1],
                                  wirelessProductID: UInt16(report[6]) << 8 | UInt16(report[5]),
                                  kind: report[4] & 0x0F)
        return .connected(device, online: report[4] & 0x40 == 0)
    }

    static func errorCode(in report: [UInt8]) -> UInt8? {
        guard isValidReport(report),
              (report[0] == 0x10 && report[2] == 0x8F) || report[2] == 0xFF else { return nil }
        return report[5]
    }

    static func rootControlsRequest(slot: UInt8) -> [UInt8]? {
        guard slots.contains(slot) else { return nil }
        return [0x11, slot, 0, 1, 0x1B, 0x04] + [UInt8](repeating: 0, count: 14)
    }

    static func restoreThumbRequest(slot: UInt8, feature: UInt8) -> [UInt8]? {
        guard slots.contains(slot), feature > 0, feature < 0x80 else { return nil }
        return [0x11, slot, feature, 0x31]
            + LogitechHIDPPProtocol.reportingParameters(cid: 0x00D0, divert: false)
            + [UInt8](repeating: 0, count: 11)
    }

    static func isThumbReportingRequest(_ report: [UInt8]) -> Bool {
        isValidReport(report) && report[0] == 0x11 && slots.contains(report[1])
            && report[2] > 0 && report[2] < 0x80 && report[3] >> 4 == 3
            && report[4] == 0 && report[5] == 0xD0
            && (report[6] == 2 || report[6] == 3) && report[7] == 0 && report[8] == 0
    }
}

/// Authorization and conservative write leases live next to the wire, not the UI. A failed
/// logical session must not lose track of a thumb it may already have diverted. A new divert
/// gets a new lease, so an old restoration can never undo a later successful re-capture.
struct LogitechUnifyingSlotState {
    private var authorized: Set<UInt8> = []
    private var leases: [UInt8: UUID] = [:]

    func accepts(slot: UInt8) -> Bool { authorized.contains(slot) }
    var restorationSlots: Set<UInt8> { Set(leases.keys).intersection(authorized) }
    func lease(slot: UInt8) -> UUID? { authorized.contains(slot) ? leases[slot] : nil }

    mutating func observe(_ device: LogitechUnifyingProtocol.PairedDevice) {
        guard LogitechUnifyingProtocol.slots.contains(device.slot) else { return }
        if device.isM720 { authorized.insert(device.slot) }
        else { invalidate(slot: device.slot) }
    }

    mutating func observe(_ notification: LogitechUnifyingProtocol.LinkNotification) {
        switch notification {
        case let .disconnected(slot): invalidate(slot: slot)
        case let .connected(device, online):
            if online { observe(device) }
            else { invalidate(slot: device.slot) }
        }
    }

    private mutating func invalidate(slot: UInt8) {
        authorized.remove(slot)
        leases.removeValue(forKey: slot)
    }

    mutating func submitted(_ request: [UInt8], id: UUID) {
        guard LogitechUnifyingProtocol.isThumbReportingRequest(request), accepts(slot: request[1]),
              request[6] == 3 else { return }
        // Submission might change the device even if its acknowledgement is lost. Retain the
        // obligation to restore until an acknowledged clear or an actual topology change.
        leases[request[1]] = id
    }

    mutating func completed(_ request: [UInt8], reply: [UInt8]) {
        guard LogitechUnifyingProtocol.isThumbReportingRequest(request), request[6] == 2,
              LogitechUnifyingProtocol.errorCode(in: reply) == nil else { return }
        leases.removeValue(forKey: request[1])
    }
}

/// One physical receiver permits one command in flight, even when it routes several slots.
/// Queueing alone is insufficient: replies must match slot, command and software ID; an old
/// root-feature reply after a timeout must not satisfy a new discovery request.
struct LogitechHIDPPTransactionQueue {
    static let capacity = 32

    struct Request {
        let id: UUID
        let original: [UInt8]
        let wire: [UInt8]
    }

    private(set) var active: Request?
    private var waiting: [(id: UUID, report: [UInt8])] = []
    private var nextSoftwareID: UInt8 = 1
    var isEmpty: Bool { active == nil && waiting.isEmpty }

    mutating func enqueue(_ report: [UInt8]) -> UUID? {
        guard LogitechUnifyingProtocol.isValidReport(report),
              report[1] == 0xFF || LogitechUnifyingProtocol.slots.contains(report[1]),
              waiting.count + (active == nil ? 0 : 1) < Self.capacity else { return nil }
        let id = UUID()
        waiting.append((id, report))
        return id
    }

    mutating func beginNext() -> Request? {
        guard active == nil, !waiting.isEmpty else { return nil }
        let item = waiting.removeFirst()
        var wire = item.report
        if wire[1] != 0xFF, wire[2] < 0x80 {
            wire[3] = (wire[3] & 0xF0) | nextSoftwareID
            nextSoftwareID = nextSoftwareID == 15 ? 1 : nextSoftwareID + 1
        }
        let request = Request(id: item.id, original: item.report, wire: wire)
        active = request
        return request
    }

    mutating func complete(with report: [UInt8]) -> (request: Request, reply: [UInt8])? {
        guard let request = active, Self.matches(report, request: request.wire) else { return nil }
        active = nil
        var reply = report
        if request.original[1] != 0xFF, request.original[2] < 0x80 {
            // The device session still uses its existing software ID. Correlation is private
            // to this shared physical transport, including the embedded function in errors.
            if reply[2] == 0xFF || reply[2] == 0x8F { reply[4] = request.original[3] }
            else { reply[3] = request.original[3] }
        }
        return (request, reply)
    }

    mutating func failActive() -> Request? {
        defer { active = nil }
        return active
    }

    mutating func cancel(slot: UInt8? = nil, includingActive: Bool = true) -> [UUID] {
        var cancelled = waiting.filter { slot == nil || $0.report[1] == slot }.map { $0.id }
        waiting.removeAll { slot == nil || $0.report[1] == slot }
        if includingActive, let request = active, slot == nil || request.original[1] == slot {
            cancelled.append(request.id)
            active = nil
        }
        return cancelled
    }

    static func matches(_ reply: [UInt8], request: [UInt8]) -> Bool {
        guard LogitechUnifyingProtocol.isValidReport(reply),
              LogitechUnifyingProtocol.isValidReport(request), reply[1] == request[1] else { return false }
        if LogitechUnifyingProtocol.errorCode(in: reply) != nil {
            return reply[3] == request[2] && reply[4] == request[3]
        }
        guard reply[2] == request[2], reply[3] == request[3] else { return false }
        if request[1] == 0xFF, request[2] == 0x83, request[3] == 0xB5 {
            return reply[4] == request[4]
        }
        return true
    }
}

/// Logical button numbers are shared by bindings, but one receiver/BT mouse releasing a key
/// must not end another mouse's still-active hold. This also makes endpoint teardown idempotent.
struct LogitechHIDPPButtonOwners {
    private var sources: [UUID: Set<Int>] = [:]

    mutating func update(source: UUID, button: Int, isDown: Bool) -> Bool {
        let wasDown = sources.values.contains { $0.contains(button) }
        if isDown { sources[source, default: []].insert(button) }
        else {
            sources[source]?.remove(button)
            if sources[source]?.isEmpty == true { sources.removeValue(forKey: source) }
        }
        let isHeld = sources.values.contains { $0.contains(button) }
        return wasDown != isHeld
    }
}
