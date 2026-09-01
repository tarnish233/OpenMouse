import Foundation

/// The two hardware DPI values used by the Logitech "toggle DPI" button action.
///
/// M750-family mice expose 400...4000 DPI in 100-DPI increments. Keeping validation next to the
/// persisted payload means malformed or hand-edited settings can never send an unsupported value
/// to the device.
struct LogitechDPILevels: Codable, Equatable, Hashable, Sendable {
    static let minimum = 400
    static let maximum = 4_000
    static let step = 100
    static let `default` = LogitechDPILevels(lower: 1_000, upper: 1_600)
    static let choices = Array(stride(from: minimum, through: maximum, by: step))

    var lower: Int
    var upper: Int

    init(lower: Int, upper: Int) {
        let first = Self.normalized(lower)
        let second = Self.normalized(upper)
        if first == second {
            if first < Self.maximum {
                self.lower = first
                self.upper = first + Self.step
            } else {
                self.lower = first - Self.step
                self.upper = first
            }
        } else {
            self.lower = min(first, second)
            self.upper = max(first, second)
        }
    }

    /// If the device is already on either configured value, switch to the other one. A DPI value
    /// outside the pair means the user just changed this action, so the first press establishes the
    /// lower/default value rather than making a proximity guess.
    func target(after current: Int) -> Int {
        current == lower ? upper : lower
    }

    /// Returns the configured button that represents the device's reported hardware DPI.
    /// Values outside the pair are kept visible separately rather than highlighting a lie.
    func activeLevel(for reportedDPI: Int?) -> Int? {
        guard let reportedDPI, reportedDPI == lower || reportedDPI == upper else { return nil }
        return reportedDPI
    }

    private static func normalized(_ value: Int) -> Int {
        let clamped = min(max(value, minimum), maximum)
        let offset = clamped - minimum
        let roundedSteps = Int((Double(offset) / Double(step)).rounded())
        return minimum + roundedSteps * step
    }

    private enum CodingKeys: CodingKey {
        case lower
        case upper
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .default
            return
        }
        self.init(
            lower: (try? container.decode(Int.self, forKey: .lower)) ?? Self.default.lower,
            upper: (try? container.decode(Int.self, forKey: .upper)) ?? Self.default.upper
        )
    }
}
