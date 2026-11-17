import Foundation
import IOKit
import IOKit.hid
import os

/// Protected vendor interfaces may be absent from IOHIDManager's macOS enumeration. Use
/// registry arrival/removal notifications, then validate PID and usage pairs before opening.
/// A receiver's keyboard and ordinary mouse interfaces are never opened by this discovery.
@MainActor
final class LogitechUnifyingDiscovery {
    private static let log = Logger(subsystem: "com.openmouse.OpenMouse", category: "hidpp")
    private let onMatched: (UInt64, IOHIDDevice) -> Void
    private let onRemoved: (UInt64) -> Void
    private var port: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private(set) var isRunning = false
    private(set) var presentIDs: Set<UInt64> = []
    private var rescanGeneration: UInt64 = 0
    private var rescanInFlight = false

    nonisolated static var matchingCriteria: [String: Any] {
        [kIOProviderClassKey: "IOHIDDevice",
         kIOPropertyMatchKey: [kIOHIDVendorIDKey: LogitechHIDPPDevicePolicy.vendorID]]
    }

    init(onMatched: @escaping (UInt64, IOHIDDevice) -> Void, onRemoved: @escaping (UInt64) -> Void) {
        self.onMatched = onMatched
        self.onRemoved = onRemoved
    }

    func start() {
        guard !isRunning, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        rescanGeneration &+= 1
        isRunning = true
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let matched = IOServiceAddMatchingNotification(
            port, kIOMatchedNotification, Self.matchingCriteria as CFDictionary,
            Self.matched, context, &matchedIterator
        )
        let removed = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, Self.matchingCriteria as CFDictionary,
            Self.removed, context, &removedIterator
        )
        guard matched == kIOReturnSuccess, removed == kIOReturnSuccess else {
            Self.log.error("Unifying registry notification setup failed matched=\(matched) removed=\(removed)")
            stop()
            return
        }
        // Both initial iterators must be drained to arm their notifications. Initial
        // termination entries do not mean an already-present receiver just disappeared.
        drainMatches(matchedIterator)
        Self.drainDiscarding(removedIterator)
    }

    func stop() {
        isRunning = false
        rescanGeneration &+= 1
        rescanInFlight = false
        if matchedIterator != 0 { IOObjectRelease(matchedIterator); matchedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
        presentIDs.removeAll()
    }

    func rescan() {
        guard isRunning, !rescanInFlight else { return }
        rescanInFlight = true
        let generation = rescanGeneration
        // Capture/wake retries must not synchronously enumerate devices in a SwiftUI onAppear
        // or on the tap run loop. Reject results invalidated by stop or device termination.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let devices = Self.collectDevices()
            DispatchQueue.main.async {
                guard let self, self.isRunning, self.rescanGeneration == generation else { return }
                self.rescanInFlight = false
                for (id, device) in devices {
                    self.presentIDs.insert(id)
                    self.onMatched(id, device)
                }
            }
        }
    }

    nonisolated private static func collectDevices() -> [(UInt64, IOHIDDevice)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingCriteria as CFDictionary, &iterator)
                == kIOReturnSuccess else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [(UInt64, IOHIDDevice)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let candidate = candidate(service) { devices.append(candidate) }
        }
        return devices
    }

    private func drainMatches(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard isRunning else { continue }
            guard let (id, device) = Self.candidate(service) else { continue }
            presentIDs.insert(id)
            onMatched(id, device)
        }
    }

    private func drainRemoved(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            rescanGeneration &+= 1
            rescanInFlight = false
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == kIOReturnSuccess,
                  presentIDs.remove(id) != nil else { continue }
            onRemoved(id)
        }
    }

    nonisolated private static func candidate(_ service: io_service_t) -> (UInt64, IOHIDDevice)? {
        let vendor = intProperty(service, kIOHIDVendorIDKey)
        let product = intProperty(service, kIOHIDProductIDKey)
        guard vendor == LogitechHIDPPDevicePolicy.vendorID,
              LogitechUnifyingProtocol.receiverProductIDs.contains(product) else { return nil }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == kIOReturnSuccess,
              let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return nil }
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let usages = LogitechUnifyingProtocol.usages(
            from: IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
        )
        guard LogitechUnifyingProtocol.acceptsInterface(
            vendorID: vendor, productID: product, transport: transport, usages: usages
        ) else { return nil }
        return (id, device)
    }

    nonisolated private static func intProperty(_ service: io_service_t, _ key: String) -> Int {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int ?? 0
    }

    nonisolated private static func drainDiscarding(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }

    private static let matched: IOServiceMatchingCallback = { context, iterator in
        guard let context else { drainDiscarding(iterator); return }
        MainActor.assumeIsolated {
            let discovery = Unmanaged<LogitechUnifyingDiscovery>.fromOpaque(context).takeUnretainedValue()
            if discovery.isRunning, iterator == discovery.matchedIterator { discovery.drainMatches(iterator) }
            else { drainDiscarding(iterator) }
        }
    }

    private static let removed: IOServiceMatchingCallback = { context, iterator in
        guard let context else { drainDiscarding(iterator); return }
        MainActor.assumeIsolated {
            let discovery = Unmanaged<LogitechUnifyingDiscovery>.fromOpaque(context).takeUnretainedValue()
            if discovery.isRunning, iterator == discovery.removedIterator { discovery.drainRemoved(iterator) }
            else { drainDiscarding(iterator) }
        }
    }
}
