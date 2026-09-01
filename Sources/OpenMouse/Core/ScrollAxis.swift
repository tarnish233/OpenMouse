import Foundation

/// The easing state for one scroll axis, factored out of the animator so the curve can be
/// reasoned about (and tested) without a display timer or event posting.
///
/// The model is exponential decay: every frame emits a fixed fraction of the distance that
/// is still owed. Two consequences make it a good fit for scrolling:
/// - New input during a glide just adds to the debt, so consecutive notches blend instead
///   of restarting an animation.
/// - The emitted step shrinks over time, which reads as inertia slowing down.
struct ScrollAxis: Equatable {
    /// Pixels still owed to the application.
    private(set) var remaining: Double = 0

    /// Below one pixel the remaining travel is imperceptible, so it is paid out at once
    /// instead of decaying for dozens more frames. This is also what guarantees the
    /// animation terminates, and it matches the 1 px dead zone Mos settles at.
    static let settleThreshold: Double = 1.0

    var isIdle: Bool { remaining == 0 }

    mutating func add(_ delta: Double) {
        // Third-party drivers still enter through CGEvent, and a malformed NaN/Inf would make
        // every termination comparison false. Reject it at the accumulator boundary rather
        // than leaving a 120 Hz ticker permanently alive.
        guard delta.isFinite, delta != 0 else { return }
        // A flick in the opposite direction should feel immediate rather than fight the
        // leftover momentum, so discard the debt when the sign flips.
        if remaining != 0, (remaining > 0) != (delta > 0) {
            remaining = delta
        } else {
            let updated = remaining + delta
            // Finite inputs can still overflow when accumulated. Resetting is preferable to
            // poisoning the animator forever; the router's normal ranges never approach this.
            remaining = updated.isFinite ? updated : 0
        }
    }

    mutating func reset() {
        remaining = 0
    }

    /// Consume one frame's worth of travel and return it.
    /// - Parameter rate: fraction of the remaining distance to emit, in 0…1.
    mutating func advance(rate: Double) -> Double {
        guard remaining.isFinite, rate.isFinite else {
            reset()
            return 0
        }
        guard remaining != 0 else { return 0 }
        var step = remaining * rate
        guard step.isFinite else {
            reset()
            return 0
        }
        if abs(remaining) < Self.settleThreshold {
            step = remaining
        }
        remaining -= step
        if abs(remaining) < 0.001 { remaining = 0 }
        return step
    }

    /// Map the user-facing smoothness slider onto a per-frame decay fraction.
    ///
    /// The fraction is exactly what Mos calls `durationTransition`, and the two apps run
    /// the same recurrence (`step = remaining × rate`). OpenMouse's tuned default smoothness
    /// of 0.87 maps to a 0.13 rate, roughly equivalent to a Mos duration of 3.94.
    static func rate(forSmoothness smoothness: Double) -> Double {
        let clamped = min(max(smoothness, 0), ScrollSettings.maxSmoothness)
        return min(max(1.0 - clamped, 1.0 - ScrollSettings.maxSmoothness), 1.0)
    }
}
