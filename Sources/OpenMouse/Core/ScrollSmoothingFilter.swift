import Foundation

/// Second-stage smoothing applied to the interpolator's output.
///
/// Interpolation alone still starts each notch with a jump: the first frame emits
/// `distance × rate`, which at the tuned defaults is ~13.7 px out of nowhere. That leading
/// edge is what reads as a flick or judder at the start of every scroll. A one-pole low-pass
/// on the output ramps it in over a handful of frames instead.
///
/// This mirrors Mos's `ScrollFilter` ("曲线峰值滤波, 用于去除滚动的起始抖动"). Mos expresses it
/// as a five-element window built by `polish`, but only elements 0 and 1 are ever read, so
/// the effective recurrence is exactly the two lines below — a low-pass with coefficient
/// 0.23 whose output lags the input by one frame. The lag is reproduced deliberately: it is
/// part of the feel being matched.
struct ScrollSmoothingFilter: Equatable {
    /// Mos's `polish` blends 23% of the distance to the new value each frame.
    static let defaultCoefficient: Double = 0.23

    private let coefficient: Double
    /// Filter state. The value emitted this frame is the state *before* folding in the new
    /// input, which is where the one-frame lag comes from.
    private var state: Double = 0

    init(coefficient: Double = defaultCoefficient) {
        self.coefficient = coefficient
    }

    /// Feed one frame of interpolator output, get the value to actually post.
    mutating func filter(_ input: Double) -> Double {
        let output = state
        state += coefficient * (input - state)
        return output
    }

    /// True while the filter still holds enough energy to be worth another frame. Without
    /// this the animation would be cut off before the tail drains and travel would be lost.
    var isDraining: Bool {
        abs(state) >= 0.001
    }

    mutating func reset() {
        state = 0
    }
}
