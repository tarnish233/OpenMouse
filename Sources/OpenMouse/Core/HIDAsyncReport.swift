import IOKit
import IOKit.hid

/// Owns output bytes until Apple's asynchronous SetReport callback (including abort).
/// An Array.withUnsafeBytes scope would end too soon. Never retain the device here: the
/// session must be able to unschedule/close it and let IOKit abort pending callbacks.
final class HIDAsyncReport {
    typealias Submit = (
        UnsafePointer<UInt8>, Int, IOHIDReportCallback, UnsafeMutableRawPointer
    ) -> IOReturn

    private let bytes: UnsafeMutablePointer<UInt8>
    private let count: Int
    private let completion: (IOReturn) -> Void

    private init(_ report: [UInt8], completion: @escaping (IOReturn) -> Void) {
        count = report.count
        bytes = .allocate(capacity: max(1, count))
        bytes.initialize(from: report, count: count)
        self.completion = completion
    }

    deinit {
        bytes.deinitialize(count: count)
        bytes.deallocate()
    }

    /// A successful submission is not a successful HID++ reply. Callers keep their protocol
    /// timeout and only update the displayed DPI after the input-report acknowledgement.
    static func send(
        _ report: [UInt8],
        submit: Submit,
        completion: @escaping (IOReturn) -> Void
    ) -> IOReturn {
        let packet = HIDAsyncReport(report, completion: completion)
        let retained = Unmanaged.passRetained(packet)
        let result = submit(packet.bytes, packet.count, callback, retained.toOpaque())
        if result != kIOReturnSuccess {
            // IOKit does not invoke the callback when submission itself fails.
            retained.release()
        }
        return result
    }

    private static let callback: IOHIDReportCallback = { context, result, _, _, _, _, _ in
        guard let context else { return }
        let packet = Unmanaged<HIDAsyncReport>.fromOpaque(context).takeRetainedValue()
        packet.completion(result)
    }
}
