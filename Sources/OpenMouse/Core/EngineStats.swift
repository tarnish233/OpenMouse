import Foundation

/// Live counters for the event pipeline. Surfaced in 通用 › 诊断 so "is this thing actually
/// doing anything?" has an answer that does not require a debugger.
struct EngineStats: Equatable, Sendable {
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

    var totalWheelEvents: Int { wheelEventsSmoothed + wheelEventsPassedThrough }

    /// Synthetic events emitted per swallowed notch. For a single isolated notch this is
    /// the length of its glide; during continuous scrolling consecutive notches merge into
    /// one glide, so the ratio drops. Either way, a value above 1 means smoothing is live.
    var amplification: Double? {
        guard wheelEventsSmoothed > 0 else { return nil }
        return Double(syntheticEventsPosted) / Double(wheelEventsSmoothed)
    }
}
