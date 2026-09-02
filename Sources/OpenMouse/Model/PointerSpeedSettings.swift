import Foundation

/// Constants for the per-device pointer acceleration curve.
///
/// Every number here is measured or copied from a shipping tool — none are invented. See the
/// "指针速度" section of CLAUDE.md for why this is an acceleration *curve* and not a DPI knob.
enum PointerSpeed {
    /// What macOS itself uses when nothing has overridden the curve.
    ///
    /// Three independent sources agree on this value: reading `HIDMouseAcceleration` off a live
    /// mouse service, reading the system-wide property off `IOHIDSystem`, and LinearMouse's
    /// hardcoded `Device.fallbackPointerAcceleration`. All three give 45056 in 16.16 fixed
    /// point. It is only a fallback here — `PointerSpeedController` prefers the live system
    /// value, which cannot go stale when the user moves the system tracking-speed slider.
    static let systemDefault = 0.6875

    /// Matches LinearMouse's slider bounds. Deliberately far wider than the useful zone:
    /// measured on this machine 0.25 is clearly slow, 0.6875 is stock, 2.0 is clearly fast.
    /// That is why the UI pairs the slider with a numeric field — at this range a slider alone
    /// cannot resolve the tenths that actually matter.
    static let range = 0.0...40.0

    /// What the slider spans, which is deliberately narrower than what can be stored.
    ///
    /// A slider over the full 0–40 puts every value anyone actually wants inside its first
    /// 5%, so it cannot resolve the tenths that matter. This covers the measured span with
    /// roughly 6× headroom over stock, and the numeric field beside it still accepts the whole
    /// stored range — so nothing is unreachable, it is only the coarse control that is scoped.
    static let sliderRange = 0.0...4.0

    /// Fine enough to land on the measured values exactly (0.0625 = 4096 in 16.16).
    static let sliderStep = 0.0625

    /// The slider's actual span, stretched when a value typed into the numeric field sits beyond
    /// the default zone — otherwise a hand-entered 10 would sit pinned at the slider's maximum and
    /// jump back to 4 the moment the slider was touched.
    static func sliderBounds(for value: Double) -> ClosedRange<Double> {
        sliderRange.lowerBound...max(sliderRange.upperBound, clamped(value))
    }

    /// Snaps to `sliderStep` within the given bounds. The slider carries no tick marks, so the
    /// quantizing has to happen in the binding rather than in the control.
    static func snapped(_ value: Double, within bounds: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return systemDefault }
        let bounded = min(max(value, bounds.lowerBound), bounds.upperBound)
        let steps = ((bounded - bounds.lowerBound) / sliderStep).rounded()
        return min(max(bounds.lowerBound + steps * sliderStep, bounds.lowerBound), bounds.upperBound)
    }

    /// HID pointer properties are `IOFixed`: a 16.16 fixed-point integer.
    static let fixedOne = 65_536.0

    /// Guards the stored value. A non-finite number would turn into a garbage `Int` on the way
    /// to `IOFixed`, so it degrades to the default rather than being clamped to a bound.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return systemDefault }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func fixed(_ value: Double) -> Int {
        Int((clamped(value) * fixedOne).rounded())
    }

    /// Deliberately unclamped: this reports what the system actually holds, including values
    /// another tool may have written outside our range. Clamping here would make a foreign
    /// value read back as one of ours.
    static func value(fromFixed fixed: Int) -> Double {
        Double(fixed) / fixedOne
    }
}

/// How a device is identified across disconnects.
///
/// Vendor + product ID rather than name or serial number: both of those change when a device is
/// re-paired or reconnected (LinearMouse #764 / #1102), which would silently orphan the user's
/// setting. Two accepted costs: two identical mice share one row, and no-name vendors ship
/// colliding IDs. Losing a setting on every reconnect is the worse failure, and reconnects are
/// far more common than owning two of the same mouse.
struct PointerDeviceKey: Equatable, Hashable, Sendable {
    var vendorID: Int
    var productID: Int
}

/// One row of the pointer-speed list.
struct PointerSpeedDevice: Codable, Equatable, Hashable, Sendable, Identifiable {
    var vendorID: Int
    var productID: Int
    /// Display only, never identity. Stored so a row can still name itself while the device is
    /// offline — otherwise a disconnected mouse becomes an anonymous pair of hex numbers.
    var name: String
    var enabled: Bool
    var acceleration: Double

    var key: PointerDeviceKey { PointerDeviceKey(vendorID: vendorID, productID: productID) }
    var id: PointerDeviceKey { key }

    init(
        vendorID: Int,
        productID: Int,
        name: String,
        enabled: Bool = false,
        acceleration: Double = PointerSpeed.systemDefault
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
        self.enabled = enabled
        self.acceleration = PointerSpeed.clamped(acceleration)
    }

    private enum CodingKeys: CodingKey {
        case vendorID
        case productID
        case name
        case enabled
        case acceleration
    }

    /// Field-by-field degradation, routed back through the memberwise initializer so that
    /// clamping cannot be bypassed by a hand-edited settings file.
    ///
    /// Identity is the one thing that has no default: a row that names no device cannot be
    /// matched against anything, and keeping it would show the user an un-actionable entry.
    /// Throwing here is what makes `LossyDecoded` drop just this row.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let vendorID = try? container.decode(Int.self, forKey: .vendorID),
              let productID = try? container.decode(Int.self, forKey: .productID) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "pointer speed row without a device identity"
                )
            )
        }
        self.init(
            vendorID: vendorID,
            productID: productID,
            name: (try? container.decode(String.self, forKey: .name)) ?? "",
            enabled: (try? container.decode(Bool.self, forKey: .enabled)) ?? false,
            acceleration: (try? container.decode(Double.self, forKey: .acceleration))
                ?? PointerSpeed.systemDefault
        )
    }
}

struct PointerSpeedSettings: Codable, Equatable, Sendable {
    var devices: [PointerSpeedDevice] = []

    init() {}

    init(devices: [PointerSpeedDevice]) {
        self.devices = devices
    }

    private enum CodingKeys: CodingKey {
        case devices
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        let decoded = try? container.decode([LossyDecoded<PointerSpeedDevice>].self, forKey: .devices)
        self.init(devices: decoded?.compactMap(\.value) ?? [])
    }

    /// Unenabled rows are kept: they remember a name and a value for a device that may simply
    /// be unplugged right now. Duplicates are the real hazard — a second row for one device
    /// would shadow the first, so whichever the UI edited might not be the one applied.
    mutating func normalize() {
        for index in devices.indices {
            devices[index].acceleration = PointerSpeed.clamped(devices[index].acceleration)
        }
        var seen = Set<PointerDeviceKey>()
        devices.removeAll { !seen.insert($0.key).inserted }
        devices.sort {
            ($0.vendorID, $0.productID) < ($1.vendorID, $1.productID)
        }
    }

    func device(for key: PointerDeviceKey) -> PointerSpeedDevice? {
        devices.first { $0.key == key }
    }
}
