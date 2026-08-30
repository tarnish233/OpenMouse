import AppKit
import CoreGraphics

/// Emits the pixel-precise scroll events that replace the ones we swallow.
///
/// The strategy mirrors Mos, because matching its feel means matching how it delivers:
/// - **Reuse the original event.** A copy of the wheel event the user actually generated
///   keeps its location, flags, timestamp and window targeting; only the deltas are
///   rewritten. Synthesising a fresh event loses all of that and has to guess.
/// - **Post to the originating process, not the HID tap.** `postToPid` hands the frame
///   straight to the app the notch was aimed at. Posting to `.cghidEventTap` instead would
///   re-enter our own tap on every frame, and — worse — would re-route mid-glide if the
///   pointer moved, so inertia would spill into whatever window the cursor wandered over.
struct ScrollEventPoster {
    enum Tag {
        /// Arbitrary but distinctive; "OMSE" as an integer-ish marker.
        static let magic: Int64 = 0x4F4D_5345
    }

    /// `CGScrollPhase` is not exposed to Swift as an enum, so the raw values live here.
    enum Phase: Int64 {
        case none = 0
        case began = 1
        case changed = 2
        case ended = 4
    }

    /// Everything needed to keep delivering frames for one gesture.
    struct Target {
        var event: CGEvent
        var pid: pid_t
    }

    private let source: CGEventSource?

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        source?.userData = Tag.magic
    }

    /// Snapshot the event a notch arrived on, so later frames can be delivered like it.
    static func target(from event: CGEvent) -> Target? {
        guard let copy = event.copy() else { return nil }
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        return Target(event: copy, pid: pid)
    }

    /// - Parameters:
    ///   - vertical: pixels to scroll, matching the macOS wheel sign convention.
    ///   - horizontal: pixels to scroll, right-positive.
    func post(vertical: Double, horizontal: Double, phase: Phase, target: Target?) {
        guard let event = target?.event.copy() ?? synthesise() else { return }

        // Continuous plus point deltas is the combination apps actually honour for
        // pixel-level scrolling; without `IsContinuous` they quantise back to whole lines
        // and the interpolation becomes invisible.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: vertical)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: horizontal)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: vertical)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: horizontal)
        event.setIntegerValueField(.eventSourceUserData, value: Tag.magic)

        if phase != .none {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        }

        if let pid = target?.pid, pid > 0 {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func synthesise() -> CGEvent? {
        CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        )
    }
}

/// Turns queued scroll distance into a stream of vsync-aligned pixel deltas.
///
/// Two stages, in this order, both matched to Mos:
/// 1. `ScrollAxis` — exponential decay toward the queued distance. Produces inertia.
/// 2. `ScrollSmoothingFilter` — a one-pole low-pass on that output. Removes the jump on the
///    first frame of every notch, which is the difference between "smooth" and "smooth but
///    it kicks".
final class ScrollAnimator {
    private let poster = ScrollEventPoster()
    private let state = Locked(State())
    private let stats: Locked<EngineStats>
    private var ticker: DisplayLinkTicker?

    /// Mos drops filtered output below one pixel rather than accumulating it. Matching that
    /// matters: accumulating instead means several silent frames followed by a 1 px jump,
    /// which is a stutter you can feel at the start and end of every scroll.
    private static let deadZone: Double = 1.0

    private struct State {
        var vertical = ScrollAxis()
        var horizontal = ScrollAxis()
        var filterY = ScrollSmoothingFilter()
        var filterX = ScrollSmoothingFilter()
        var rate: Double = 0.085
        var emitPhases = false
        var running = false
        var didEmitBegan = false
        var target: ScrollEventPoster.Target?
    }

    init(stats: Locked<EngineStats>) {
        self.stats = stats
    }

    /// Queue distance to travel. Called from the event-tap callback on the main thread.
    func enqueue(
        vertical: Double,
        horizontal: Double,
        settings: ScrollSettings,
        target: ScrollEventPoster.Target?
    ) {
        let rate = ScrollAxis.rate(forSmoothness: settings.smoothness)
        let shouldStart: Bool = state.withValue { state in
            state.rate = rate
            state.emitPhases = settings.emitScrollPhases
            state.vertical.add(vertical)
            state.horizontal.add(horizontal)
            if let target { state.target = target }
            guard !state.running else { return false }
            state.running = true
            return true
        }
        if shouldStart { startTicker() }
    }

    /// Throw away queued movement — used when the engine is disabled mid-glide.
    func cancel() {
        state.withValue { state in
            state.vertical.reset()
            state.horizontal.reset()
            state.filterY.reset()
            state.filterX.reset()
            state.target = nil
        }
    }

    /// Which frame source the last glide used. Read by the diagnostics.
    var frameSource: DisplayLinkTicker.Source {
        ticker?.activeSource ?? .idle
    }

    private func startTicker() {
        if ticker == nil {
            ticker = DisplayLinkTicker { [weak self] in self?.tick() }
        }
        ticker?.start()
    }

    private func stopTicker() {
        ticker?.stop()
    }

    private enum Outcome {
        case emit(vertical: Double, horizontal: Double, phase: Phase, target: ScrollEventPoster.Target?)
        case hold
        case finish(phase: Phase, target: ScrollEventPoster.Target?)

        typealias Phase = ScrollEventPoster.Phase
    }

    private func tick() {
        let outcome: Outcome = state.withValue { state in
            let stepY = state.vertical.advance(rate: state.rate)
            let stepX = state.horizontal.advance(rate: state.rate)
            let outY = state.filterY.filter(stepY)
            let outX = state.filterX.filter(stepX)

            // The filter lags its input, so the glide is not over until both the axes have
            // settled and the filter has drained. Stopping on the axes alone would clip the
            // tail off every scroll.
            let axesIdle = state.vertical.isIdle && state.horizontal.isIdle
            let drained = !state.filterY.isDraining && !state.filterX.isDraining
            if axesIdle, drained {
                state.running = false
                let phase: ScrollEventPoster.Phase = (state.emitPhases && state.didEmitBegan) ? .ended : .none
                state.didEmitBegan = false
                let target = state.target
                state.filterY.reset()
                state.filterX.reset()
                return .finish(phase: phase, target: target)
            }

            guard max(abs(outY), abs(outX)) > Self.deadZone else { return .hold }

            var phase = ScrollEventPoster.Phase.none
            if state.emitPhases {
                phase = state.didEmitBegan ? .changed : .began
                state.didEmitBegan = true
            }
            return .emit(vertical: outY, horizontal: outX, phase: phase, target: state.target)
        }

        switch outcome {
        case .hold:
            break
        case let .emit(dy, dx, phase, target):
            poster.post(vertical: dy, horizontal: dx, phase: phase, target: target)
            stats.withValue { $0.syntheticEventsPosted += 1 }
        case let .finish(phase, target):
            if phase == .ended {
                poster.post(vertical: 0, horizontal: 0, phase: .ended, target: target)
            }
            // Idle costs nothing: tear the frame source down until the next notch arrives.
            stopTicker()
        }
    }
}
