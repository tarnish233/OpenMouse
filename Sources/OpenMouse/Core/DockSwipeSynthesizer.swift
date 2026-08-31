import AppKit
import CoreGraphics
import Foundation

/// Diagnostic output edge for the private Dock gesture encoder. Production gesture navigation
/// intentionally does not use this path: a direct Logi Options+ trace showed one discrete
/// Control+Arrow shortcut per physical hold, while field-driven completion introduced jumps.
protocol GestureNavigationOutput: AnyObject {
    var supportsInteractiveNavigation: Bool { get }

    @discardableResult
    func begin(
        button: Int,
        axis: MouseGestureAxis,
        initialPixelDelta: Double,
        location: CGPoint,
        canFreezePointer: Bool
    ) -> Bool
    func change(button: Int, pixelDelta: Double)
    func allowPointerMovement(button: Int)
    func end(button: Int, cancelled: Bool)
    func cancelAll()
}

/// One logical frame in macOS's Dock-swipe state machine.
struct DockSwipeFrame: Equatable, Sendable {
    enum Phase: Int64, Equatable, Sendable {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }

    var axis: MouseGestureAxis
    var phase: Phase
    /// Accumulated gesture progress from its origin. The Dock renders the transition directly
    /// from this value, which is what makes a half-finished animation reversible.
    var progress: Double
    /// Most recent progress delta multiplied by an empirical factor on exit, matching the shape
    /// of genuine Dock-swipe events. Horizontal/vertical transitions mostly care about progress;
    /// this remains important for the same encoder to stay faithful and for future pinch use.
    var exitSpeed: Double
}

/// Stateful, interactive replacement for the former Control+Arrow gesture action.
///
/// A keyboard shortcut asks Spaces to start a fixed animation and further requests are discarded
/// until it finishes. A Dock-swipe instead has `began / changed / ended` phases and an accumulated
/// progress value. Feeding every signed mouse delta through that stream makes the animation track
/// the hand and lets an opposite delta pull it back immediately.
///
/// The field protocol is undocumented. This implementation is adapted from the MIT-licensed
/// `oomol-lab/dockswipe` project, which in turn documents the reverse-engineered Mac Mouse Fix
/// event layout. macOS 27 moved this data into an IOHIDEvent; until that path is implemented here,
/// newer systems deliberately fall back to the existing symbolic hotkeys instead of emitting an
/// event stream known to be ignored.
final class DockSwipeSynthesizer: GestureNavigationOutput {
    /// `CGAssociateMouseAndMouseCursorPosition(false)` keeps the pointer visually still, but on
    /// macOS 26 it also stops subsequent annotated-session motion samples from a BLE Logi M750 L.
    /// The Dock then receives only `began` and `ended` with almost no progress. Keep the mechanism
    /// testable for older devices, but production must preserve the input stream until a HID-level
    /// path can freeze the cursor without starving the recognizer.
    static let freezesPointerDuringProductionGesture = false

    /// Retained for explicit diagnostics and the hidden end-to-end probe. EventRouter's production
    /// default keeps `usesInteractiveGestureNavigation` false.
    static let shared = DockSwipeSynthesizer(
        freezesPointer: freezesPointerDuringProductionGesture,
        cancelPendingSpaceSwitches: {
            MainActor.assumeIsolated { SpaceSwitchPacer.shared.cancel() }
        }
    )

    /// Extra end events mitigate a long-standing system failure mode where the Dock occasionally
    /// misses the first exit frame under load. A new gesture synchronously cancels these before
    /// posting `began`, otherwise a stale exit could cancel the user's reversal.
    static let defaultEndResendDelays: [TimeInterval] = [0.2, 0.5]

    private struct ProgressSample {
        var time: TimeInterval
        var progress: Double
    }

    private struct ActiveGesture {
        var button: Int
        var axis: MouseGestureAxis
        var scale: Double
        var progress: Double
        var samples: [ProgressSample]
    }

    /// Mouse motion is much shorter than a trackpad's coordinate travel. Without this gain a
    /// 150 px flick only reaches about 0.1 Dock progress and always falls back. Logi's recognizer
    /// likewise combines progress and velocity thresholds rather than requiring screen-width
    /// travel. Four times the raw Dock calibration makes roughly 100–200 px useful while the
    /// clamp below prevents a large gaming-mouse flick from overshooting several transitions.
    static let pointerProgressGain: Double = 4
    static let maximumProgressMagnitude: Double = 1.25
    static let distanceCommitProgress: Double = 0.42
    static let velocityCommitThreshold: Double = 0.8
    static let reverseCancelVelocityThreshold: Double = 0.8
    static let minimumFlickProgress: Double = 0.07
    static let velocityWindow: TimeInterval = 0.08
    static let velocityIdleGrace: TimeInterval = 0.03
    static let velocityDecayTime: TimeInterval = 0.08
    static let maximumExitSpeed: Double = 3.5

    let supportsInteractiveNavigation: Bool
    private let screenSize: (CGPoint) -> CGSize
    private let postFrame: (DockSwipeFrame) -> Void
    private let endResendDelays: [TimeInterval]
    private let freezesPointer: Bool
    private let setPointerAssociation: (Bool) -> Bool
    private let cancelPendingSpaceSwitches: () -> Void
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    private let now: () -> TimeInterval

    /// EventRouter and the main event tap are main-run-loop confined. Resends also run on the
    /// main queue, so the active state never crosses threads and no lock is needed on this hot path.
    private var active: ActiveGesture?
    private var resendItems: [DispatchWorkItem] = []
    private var resendGeneration: UInt64 = 0
    private var cursorIsFrozen = false

    init(
        supportsInteractiveNavigation: Bool = DockSwipeSynthesizer.fieldProtocolIsSupported,
        screenSize: @escaping (CGPoint) -> CGSize = DockSwipeSynthesizer.defaultScreenSize,
        endResendDelays: [TimeInterval] = DockSwipeSynthesizer.defaultEndResendDelays,
        freezesPointer: Bool = false,
        setPointerAssociation: @escaping (Bool) -> Bool = { connected in
            CGAssociateMouseAndMouseCursorPosition(connected ? 1 : 0) == .success
        },
        cancelPendingSpaceSwitches: @escaping () -> Void = {},
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = {
            delay, action in
            let item = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        },
        now: @escaping () -> TimeInterval = monotonicSeconds,
        postFrame: @escaping (DockSwipeFrame) -> Void = DockSwipeEventPoster.post
    ) {
        self.supportsInteractiveNavigation = supportsInteractiveNavigation
        self.screenSize = screenSize
        self.endResendDelays = endResendDelays
        self.freezesPointer = freezesPointer
        self.setPointerAssociation = setPointerAssociation
        self.cancelPendingSpaceSwitches = cancelPendingSpaceSwitches
        self.scheduleAfter = scheduleAfter
        self.now = now
        self.postFrame = postFrame
    }

    @discardableResult
    func begin(
        button: Int,
        axis: MouseGestureAxis,
        initialPixelDelta: Double,
        location: CGPoint,
        canFreezePointer: Bool
    ) -> Bool {
        guard supportsInteractiveNavigation, initialPixelDelta.isFinite else { return false }

        let scale = Self.progressScale(for: axis, screenSize: screenSize(location))
        let progressDelta = Self.progressDelta(
            fromPixelDelta: initialPixelDelta,
            axis: axis,
            scale: scale
        )
        guard progressDelta.isFinite, progressDelta != 0 else { return false }

        // A separately bound desktop shortcut may still have paced key events queued. Letting
        // one fire during this gesture would replace the interactive transition with a fixed
        // animation at exactly the moment the user tries to reverse it.
        cancelPendingSpaceSwitches()
        cancelScheduledResends()
        // Defensive ownership handoff. Production normally ends one hold before beginning the
        // next, but cancelling here prevents two buttons from leaving the Dock in overlapping
        // gesture states.
        if let old = active {
            postFrame(exitFrame(for: old, forcedPhase: .cancelled))
            active = nil
        }

        let timestamp = now()
        let progress = Self.clampProgress(progressDelta)
        let gesture = ActiveGesture(
            button: button,
            axis: axis,
            scale: scale,
            progress: progress,
            // Seed one nominal 120 Hz sample so a very short two-frame flick still has a
            // measurable launch velocity. Later samples replace this inside the 80 ms window.
            samples: [
                ProgressSample(time: timestamp - 1.0 / 120.0, progress: 0),
                ProgressSample(time: timestamp, progress: progress)
            ]
        )
        active = gesture
        if canFreezePointer { freezePointerIfNeeded() }
        postFrame(DockSwipeFrame(
            axis: axis,
            phase: .began,
            progress: progress,
            exitSpeed: 0
        ))
        return true
    }

    func change(button: Int, pixelDelta: Double) {
        guard pixelDelta.isFinite,
              var gesture = active,
              gesture.button == button
        else { return }

        let progressDelta = Self.progressDelta(
            fromPixelDelta: pixelDelta,
            axis: gesture.axis,
            scale: gesture.scale
        )
        guard progressDelta.isFinite, progressDelta != 0 else { return }
        gesture.progress = Self.clampProgress(gesture.progress + progressDelta)
        guard gesture.progress.isFinite else {
            active = nil
            releasePointerIfNeeded()
            postFrame(exitFrame(for: gesture, forcedPhase: .cancelled))
            return
        }
        let timestamp = now()
        gesture.samples.append(ProgressSample(time: timestamp, progress: gesture.progress))
        Self.trimVelocitySamples(&gesture.samples, at: timestamp)
        active = gesture
        postFrame(DockSwipeFrame(
            axis: gesture.axis,
            phase: .changed,
            progress: gesture.progress,
            exitSpeed: 0
        ))
    }

    func allowPointerMovement(button: Int) {
        guard active?.button == button else { return }
        releasePointerIfNeeded()
    }

    func end(button: Int, cancelled: Bool) {
        guard let gesture = active, gesture.button == button else { return }
        active = nil
        releasePointerIfNeeded()

        let frame = exitFrame(
            for: gesture,
            forcedPhase: cancelled ? .cancelled : nil
        )
        Trace.interactiveGestureEnded(
            progress: gesture.progress,
            exitSpeed: frame.exitSpeed,
            cancelled: frame.phase == .cancelled
        )
        postFrame(frame)
        scheduleEndResends(frame)
    }

    func cancelAll() {
        cancelScheduledResends()
        let gesture = active
        active = nil
        releasePointerIfNeeded()
        guard let gesture else { return }
        postFrame(exitFrame(for: gesture, forcedPhase: .cancelled))
    }

    private func freezePointerIfNeeded() {
        guard freezesPointer, !cursorIsFrozen else { return }
        cursorIsFrozen = setPointerAssociation(false)
    }

    private func releasePointerIfNeeded() {
        guard cursorIsFrozen else { return }
        _ = setPointerAssociation(true)
        cursorIsFrozen = false
    }

    private func exitFrame(
        for gesture: ActiveGesture,
        forcedPhase: DockSwipeFrame.Phase?
    ) -> DockSwipeFrame {
        let velocity = Self.exitVelocity(for: gesture.samples, at: now())
        let progressSign = Self.sign(of: gesture.progress)
        let velocitySign = Self.sign(of: velocity)
        let hasDistance = abs(gesture.progress) >= Self.distanceCommitProgress
        let isFastFlick = abs(gesture.progress) >= Self.minimumFlickProgress
            && abs(velocity) >= Self.velocityCommitThreshold
            && velocitySign == progressSign
        let isStrongReversal = progressSign != 0
            && velocitySign != 0
            && velocitySign != progressSign
            && abs(velocity) >= Self.reverseCancelVelocityThreshold

        let phase: DockSwipeFrame.Phase
        if let forcedPhase {
            phase = forcedPhase
        } else if progressSign == 0 || isStrongReversal {
            phase = .cancelled
        } else if hasDistance || isFastFlick {
            phase = .ended
        } else {
            // A slow, short move is exploration rather than a command. Explicit cancellation
            // gives the Dock a deterministic rollback instead of relying on undocumented
            // progress heuristics. A short *fast* flick takes the branch above.
            phase = .cancelled
        }
        return DockSwipeFrame(
            axis: gesture.axis,
            phase: phase,
            progress: gesture.progress,
            exitSpeed: velocity
        )
    }

    private func scheduleEndResends(_ frame: DockSwipeFrame) {
        cancelScheduledResends()
        let generation = resendGeneration
        for delay in endResendDelays where delay >= 0 && delay.isFinite {
            let item = scheduleAfter(delay) { [weak self] in
                guard let self, self.resendGeneration == generation else { return }
                self.postFrame(frame)
            }
            resendItems.append(item)
        }
    }

    private func cancelScheduledResends() {
        // DispatchWorkItem cancellation is advisory. The generation guard above is the actual
        // guarantee that a stale Ended frame cannot land inside a newly begun reverse gesture.
        resendGeneration &+= 1
        resendItems.forEach { $0.cancel() }
        resendItems.removeAll()
    }

    /// Field-based Dock swipes work through macOS 26. macOS 27 ignores these CGEvent fields and
    /// requires an IOHIDEvent payload, so fail closed there and let EventRouter use hotkeys.
    static var fieldProtocolIsSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    }

    static func defaultScreenSize(at location: CGPoint) -> CGSize {
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        if location.x.isFinite, location.y.isFinite,
           CGGetDisplaysWithPoint(location, 1, &display, &count) == .success,
           count > 0 {
            return CGDisplayBounds(display).size
        }
        return NSScreen.main?.frame.size ?? CGDisplayBounds(CGMainDisplayID()).size
    }

    /// Empirical calibration used by established mouse-to-three-finger-swipe implementations:
    /// horizontal travel includes the visual Space separator; vertical progress spans one screen.
    static func progressScale(for axis: MouseGestureAxis, screenSize: CGSize) -> Double {
        switch axis {
        case .horizontal:
            // 1.5 is a stable middle ground across two-space (about 2.0) and many-space (about
            // 1.0) layouts when the private Space-counting API is intentionally avoided.
            return pointerProgressGain * 1.5 / max(1, Double(screenSize.width) + 63)
        case .vertical:
            return pointerProgressGain / max(1, Double(screenSize.height))
        }
    }

    /// Translate Core Graphics mouse coordinates into the Dock's progress convention.
    /// Horizontal progress is opposite pointer X (push left = reveal the right Space); vertical
    /// progress follows Core Graphics Y (up is negative = Mission Control). This sign adjustment
    /// is independent from field 136, which must remain clear for synthetic field-only events.
    static func progressDelta(
        fromPixelDelta delta: Double,
        axis: MouseGestureAxis,
        scale: Double
    ) -> Double {
        switch axis {
        case .horizontal: -delta * scale
        case .vertical: delta * scale
        }
    }

    private static func clampProgress(_ progress: Double) -> Double {
        min(max(progress, -maximumProgressMagnitude), maximumProgressMagnitude)
    }

    private static func trimVelocitySamples(_ samples: inout [ProgressSample], at time: TimeInterval) {
        let cutoff = time - velocityWindow
        // Preserve one sample just before the window boundary for a stable slope.
        while samples.count > 2, samples[1].time < cutoff { samples.removeFirst() }
    }

    private static func exitVelocity(
        for samples: [ProgressSample],
        at exitTime: TimeInterval
    ) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let duration = last.time - first.time
        guard duration.isFinite, duration > 0 else { return 0 }
        var velocity = (last.progress - first.progress) / duration
        guard velocity.isFinite else { return 0 }

        // A deliberate pause before release should not inherit an old flick's momentum. Preserve
        // velocity for the normal button-release latency, then decay it smoothly.
        let idle = max(0, exitTime - last.time - velocityIdleGrace)
        if idle > 0 { velocity *= exp(-idle / velocityDecayTime) }
        return min(max(velocity, -maximumExitSpeed), maximumExitSpeed)
    }

    private static func sign(of value: Double) -> Int {
        value > 0 ? 1 : value < 0 ? -1 : 0
    }

    // MARK: Testable state

    var activeButton: Int? { active?.button }
    var activeProgress: Double? { active?.progress }
}

/// Encodes the pre-macOS-27 private CGEvent field layout and posts the companion event pair.
enum DockSwipeEventPoster {
    private enum Field {
        static let eventType = make(55)
        static let magic41 = make(41)
        static let subtype = make(110)
        static let axisWeirdPrimary = make(119)
        static let axisPrimary = make(123)
        static let progress = make(124)
        static let exitSpeedPrimary = make(129)
        static let exitSpeedSecondary = make(130)
        static let phasePrimary = make(132)
        static let phaseSecondary = make(134)
        static let progressFloatBits = make(135)
        static let invertedFromDevice = make(136)
        static let axisWeirdSecondary = make(139)
        static let axisSecondary = make(165)

        private static func make(_ rawValue: UInt32) -> CGEventField {
            // These raw field IDs are the protocol. If CoreGraphics ever removes the enum
            // carrier entirely, construction should fail loudly during development.
            CGEventField(rawValue: rawValue)!
        }
    }

    private static let dockSwipeSubtype = 23
    private static let gestureEventType = 29
    private static let dockControlEventType = 30
    private static let magic41 = 33_231

    static func post(_ frame: DockSwipeFrame) {
        guard let events = makeEvents(frame) else { return }
        // The Dock-control event comes first in the observed stream, followed by its generic
        // gesture marker. Both are session events rather than application-targeted input.
        events.control.post(tap: .cgSessionEventTap)
        events.marker.post(tap: .cgSessionEventTap)
    }

    static func makeEvents(_ frame: DockSwipeFrame) -> (control: CGEvent, marker: CGEvent)? {
        guard frame.progress.isFinite, frame.exitSpeed.isFinite,
              let marker = CGEvent(source: nil),
              let control = CGEvent(source: nil)
        else { return nil }

        marker.setDoubleValueField(Field.eventType, value: Double(gestureEventType))
        marker.setDoubleValueField(Field.magic41, value: Double(magic41))

        control.setDoubleValueField(Field.eventType, value: Double(dockControlEventType))
        control.setDoubleValueField(Field.subtype, value: Double(dockSwipeSubtype))
        control.setDoubleValueField(Field.phasePrimary, value: Double(frame.phase.rawValue))
        control.setDoubleValueField(Field.phaseSecondary, value: Double(frame.phase.rawValue))
        control.setDoubleValueField(Field.progress, value: frame.progress)
        control.setIntegerValueField(
            Field.progressFloatBits,
            value: Int64(Float(frame.progress).bitPattern)
        )
        control.setDoubleValueField(Field.magic41, value: Double(magic41))

        let axisCode: UInt32 = frame.axis == .horizontal ? 1 : 2
        let weirdAxisFloat = Double(Float(bitPattern: axisCode))
        control.setDoubleValueField(Field.axisWeirdPrimary, value: weirdAxisFloat)
        control.setDoubleValueField(Field.axisWeirdSecondary, value: weirdAxisFloat)
        control.setDoubleValueField(Field.axisPrimary, value: Double(axisCode))
        control.setDoubleValueField(Field.axisSecondary, value: Double(axisCode))
        // This is not a generic "we already adjusted the sign" flag. The Dock uses it to
        // distinguish the coordinate convention of an actual device-backed gesture. The
        // pre-macOS-27 synthetic recipe used by Mac Mouse Fix/dockswipe explicitly leaves it
        // clear; setting it makes otherwise valid field-only events get ignored on macOS 26.
        control.setIntegerValueField(Field.invertedFromDevice, value: 0)

        if frame.phase == .ended || frame.phase == .cancelled {
            control.setDoubleValueField(Field.exitSpeedPrimary, value: frame.exitSpeed)
            control.setDoubleValueField(Field.exitSpeedSecondary, value: frame.exitSpeed)
        }
        return (control, marker)
    }

    /// Raw field readers used only by the built-in self-checks.
    static func doubleField(_ rawValue: UInt32, in event: CGEvent) -> Double {
        event.getDoubleValueField(CGEventField(rawValue: rawValue)!)
    }

    static func integerField(_ rawValue: UInt32, in event: CGEvent) -> Int64 {
        event.getIntegerValueField(CGEventField(rawValue: rawValue)!)
    }
}
