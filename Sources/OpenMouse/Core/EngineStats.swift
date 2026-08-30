import Foundation

/// Live counters for the event pipeline. Surfaced in 通用 › 诊断 so "is this thing actually
/// doing anything?" has an answer that does not require a debugger.
struct EngineStats: Equatable, Sendable {
    /// Which delta field the wheel magnitude was read from.
    enum RawDeltaSource: String, Equatable, Sendable {
        case point
        case fixed
        case line
        case none
    }

    /// Discrete wheel notches swallowed and handed to the animator.
    var wheelEventsSmoothed = 0
    /// Wheel notches passed through untouched (smoothing off, or reverse-only).
    var wheelEventsPassedThrough = 0
    /// Continuous (trackpad / Magic Mouse) events seen.
    var continuousEventsSeen = 0
    /// Synthetic pixel-scroll events posted by the animator.
    var syntheticEventsPosted = 0
    /// Button actions actually executed.
    var buttonActionsFired = 0
    /// Uptime timestamp of the most recent intercepted scroll event.
    var lastScrollUptime: TimeInterval?

    /// Notches we declined to smooth because the event carried no routable target process.
    /// Anything but zero means the tap is at the wrong layer: the replacement frames would
    /// have had nowhere to go, so the notch was passed through instead. This exists because
    /// the failure it guards against — a swallowed notch with an undeliverable replacement —
    /// presents to the user as a dead scroll wheel, and used to be invisible in the counters.
    var wheelEventsUndeliverable = 0
    /// Target process of the most recent smoothed notch. Zero means none was resolved.
    var lastTargetPID = 0
    /// Which delta field supplied the most recent notch's magnitude.
    var lastRawDeltaSource: RawDeltaSource = .none

    var totalWheelEvents: Int { wheelEventsSmoothed + wheelEventsPassedThrough }

    /// Synthetic events emitted per swallowed notch. For a single isolated notch this is
    /// the length of its glide; during continuous scrolling consecutive notches merge into
    /// one glide, so the ratio drops. Either way, a value above 1 means smoothing is live.
    var amplification: Double? {
        guard wheelEventsSmoothed > 0 else { return nil }
        return Double(syntheticEventsPosted) / Double(wheelEventsSmoothed)
    }
}
