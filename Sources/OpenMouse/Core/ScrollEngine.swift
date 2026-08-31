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
    ///
    /// Returns `nil` when the event carries no routable target. Callers must treat that as
    /// "do not swallow this event": there is nowhere to deliver a replacement, and a
    /// swallowed notch with no replacement is a dead scroll wheel.
    static func target(from event: CGEvent) -> Target? {
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        guard pid > 0, let copy = event.copy() else { return nil }
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
            // No routable target. The session tap re-routes by cursor location, which is the
            // right generic behaviour; it is only wrong for inertia, and inertia without a
            // target is not something we get to have.
            event.post(tap: .cgSessionEventTap)
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
    typealias TickerFactory = (@escaping () -> Void) -> ScrollFrameTicker

    private let poster = ScrollEventPoster()
    private let state = Locked(State())
    private let stats: Locked<EngineStats>
    private let tickerFactory: TickerFactory
    /// Deterministic seam used only by self-checks to inject a notch after a finish frame has
    /// been prepared but before its conditional stop is committed.
    private let beforeFinishCommit: (() -> Void)?

    /// Mos drops filtered output below one pixel rather than accumulating it. Matching that
    /// matters: accumulating instead means several silent frames followed by a 1 px jump,
    /// which is a stutter you can feel at the start and end of every scroll.
    private static let deadZone: Double = 1.0

    private struct ActiveTicker {
        var generation: UInt64
        var source: ScrollFrameTicker
    }

    private struct State {
        var vertical = ScrollAxis()
        var horizontal = ScrollAxis()
        var filterY = ScrollSmoothingFilter()
        var filterX = ScrollSmoothingFilter()
        var rate: Double = 0.085
        var emitPhases = false
        var didEmitBegan = false
        var target: ScrollEventPoster.Target?
        var ticker: ActiveTicker?
        var nextTickerGeneration: UInt64 = 0
        /// Incremented for every accepted input. A finish prepared against an older revision
        /// is stale and must not tear down the source that is now carrying the new input.
        var inputRevision: UInt64 = 0
    }

    init(
        stats: Locked<EngineStats>,
        tickerFactory: @escaping TickerFactory = { DisplayLinkTicker(onTick: $0) },
        beforeFinishCommit: (() -> Void)? = nil
    ) {
        self.stats = stats
        self.tickerFactory = tickerFactory
        self.beforeFinishCommit = beforeFinishCommit
    }

    /// Queue distance to travel. Called from the event-tap callback on the main thread.
    @discardableResult
    func enqueue(
        vertical: Double,
        horizontal: Double,
        settings: ScrollSettings,
        target: ScrollEventPoster.Target?
    ) -> Bool {
        // This is the last mandatory gate before values enter the easing/filter state. The
        // router uses the return value to pass a malformed original event through instead of
        // swallowing it without a replacement.
        guard vertical.isFinite, horizontal.isFinite,
              vertical != 0 || horizontal != 0 else { return false }

        let rate = ScrollAxis.rate(forSmoothness: settings.smoothness)
        guard rate.isFinite else { return false }
        return state.withValue { state in
            state.rate = rate
            state.emitPhases = settings.emitScrollPhases
            state.vertical.add(vertical)
            state.horizontal.add(horizontal)
            if let target { state.target = target }
            state.inputRevision &+= 1

            // The optional ticker is the only lifecycle truth. Publishing it and starting its
            // underlying link/timer happen while this same lock is held, so no observer can see
            // "running" without a live source (or vice versa).
            guard state.ticker == nil else { return true }
            state.nextTickerGeneration &+= 1
            let generation = state.nextTickerGeneration
            let ticker = tickerFactory { [weak self] in
                self?.tick(tickerGeneration: generation)
            }
            guard ticker.start() else {
                state.vertical.reset()
                state.horizontal.reset()
                state.filterY.reset()
                state.filterX.reset()
                state.didEmitBegan = false
                state.target = nil
                return false
            }
            state.ticker = ActiveTicker(generation: generation, source: ticker)
            return true
        }
    }

    /// Throw away queued movement — used when the engine is disabled mid-glide.
    func cancel() {
        state.withValue { state in
            state.vertical.reset()
            state.horizontal.reset()
            state.filterY.reset()
            state.filterX.reset()
            state.didEmitBegan = false
            state.target = nil
            state.inputRevision &+= 1
            state.ticker?.source.stop()
            state.ticker = nil
        }
    }

    /// Which frame source the last glide used. Read by the diagnostics.
    var frameSource: DisplayLinkTicker.Source {
        state.withValue { state in
            state.ticker?.source.activeSource ?? .idle
        }
    }

    /// Internal diagnostics used by self-checks to pin the lifecycle invariant.
    var isRunning: Bool {
        state.withValue { $0.ticker != nil }
    }

    var hasLiveFrameSource: Bool {
        state.withValue { state in
            state.ticker?.source.isRunning ?? false
        }
    }

    private enum Outcome {
        case ignore
        case emit(vertical: Double, horizontal: Double, phase: Phase, target: ScrollEventPoster.Target?)
        case hold
        case finish(Finish)

        typealias Phase = ScrollEventPoster.Phase
    }

    private struct Finish {
        var tickerGeneration: UInt64
        var inputRevision: UInt64
        var phase: ScrollEventPoster.Phase
        var target: ScrollEventPoster.Target?
    }

    private func tick(tickerGeneration: UInt64) {
        let outcome: Outcome = state.withValue { state in
            // A callback already queued when an old source was stopped may arrive after a new
            // glide has started. Its generation cannot be allowed to advance or stop the new
            // source.
            guard state.ticker?.generation == tickerGeneration else { return .ignore }

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
                let phase: ScrollEventPoster.Phase = (state.emitPhases && state.didEmitBegan) ? .ended : .none
                state.didEmitBegan = false
                state.filterY.reset()
                state.filterX.reset()
                return .finish(Finish(
                    tickerGeneration: tickerGeneration,
                    inputRevision: state.inputRevision,
                    phase: phase,
                    target: state.target
                ))
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
        case .ignore:
            break
        case .hold:
            break
        case let .emit(dy, dx, phase, target):
            poster.post(vertical: dy, horizontal: dx, phase: phase, target: target)
            stats.withValue { $0.syntheticEventsPosted += 1 }
        case let .finish(finish):
            if finish.phase == .ended {
                poster.post(vertical: 0, horizontal: 0, phase: .ended, target: finish.target)
            }

            // A new notch is allowed to arrive while the ended event is being posted. It reuses
            // the still-live source and increments `inputRevision`; the stale finish then fails
            // this conditional commit instead of stopping that source underneath the new glide.
            beforeFinishCommit?()
            state.withValue { state in
                guard state.ticker?.generation == finish.tickerGeneration,
                      state.inputRevision == finish.inputRevision else { return }

                // Stop and remove are one transition under the same lifecycle lock. An enqueue
                // either sees the old live source or waits and starts a new one after it is gone.
                state.ticker?.source.stop()
                state.ticker = nil
                state.target = nil
            }
        }
    }
}
