import CoreGraphics
import Foundation

/// The decision layer: inspects every intercepted event and decides whether to pass it
/// through, rewrite it, or swallow it and synthesise something better.
final class EventRouter {
    /// Modifier bits we honour for per-modifier button bindings. Masking is important:
    /// raw `CGEventFlags` also carry noise like the non-coalesced and numeric-pad bits.
    static let modifierMask: UInt64 = CGEventFlags([
        .maskCommand, .maskShift, .maskAlternate, .maskControl
    ]).rawValue

    /// Live pipeline counters, readable from any thread.
    let stats = Locked(EngineStats())

    private let animator: ScrollAnimator
    private let actions = ActionRunner()

    private let config: Locked<ResolvedConfig>
    private let bindings = Locked<[ButtonBinding]>([])
    /// When set, button presses are reported here (with the modifiers held) and swallowed
    /// instead of being acted on, so the settings UI can record a binding from a real press.
    private let captureHandler = Locked<((Int, UInt64) -> Void)?>(nil)

    /// Timestamp of the last wheel notch, for the flywheel acceleration curve.
    private var lastNotchTime: CFTimeInterval = 0
    /// Active gesture-navigation holds, keyed by button number. A dictionary rather than a
    /// single slot because two buttons can be bound to gestures and held at once.
    private var gestureSessions: [Int: MouseGestureRecognizer] = [:]
    /// Motion events seen in the current hold, so tracing can log the first few and stop.
    private var motionEventCount = 0

    /// Called when a gesture hold begins or ends, so the engine can bring up the motion tap
    /// only while one is in progress. Subscribing to every pointer movement permanently would
    /// burn CPU for a feature that is idle almost all of the time.
    var onGestureActivityChanged: ((Bool) -> Void)?

    init(config: Locked<ResolvedConfig>) {
        self.config = config
        animator = ScrollAnimator(stats: stats)
    }

    func resetStats() {
        stats.value = EngineStats()
    }

    func setCaptureHandler(_ handler: ((Int, UInt64) -> Void)?) {
        captureHandler.value = handler
    }

    func updateBindings(_ list: [ButtonBinding]) {
        bindings.value = list.filter(\.isActive)
    }

    /// Frame source in use for the current or most recent glide.
    var frameSource: DisplayLinkTicker.Source { animator.frameSource }

    func cancelInFlightScrolling() {
        animator.cancel()
    }

    /// Drop any in-progress gesture. Called when the system disables a tap mid-hold, which
    /// would otherwise leave a session armed with no button-up coming to close it.
    func cancelGestures() {
        guard !gestureSessions.isEmpty else { return }
        gestureSessions.removeAll()
        onGestureActivityChanged?(false)
    }

    // MARK: - Entry point

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Anything we posted ourselves must never be reprocessed, or a single notch would
        // feed back into the animator forever.
        if SyntheticEventTag.isMarked(event) {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .scrollWheel:
            return handleScroll(event)
        case .otherMouseDown, .otherMouseUp:
            return handleButton(type: type, event: event)
        case .mouseMoved, .otherMouseDragged, .leftMouseDragged, .rightMouseDragged:
            return handleMotion(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Scrolling

    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let config = config.value
        guard config.active else { return Unmanaged.passUnretained(event) }
        let settings = config.scroll

        // A continuous event means the device already reports pixel-level deltas:
        // a trackpad, a Magic Mouse, or a mouse with a hi-res driver. Those are smooth
        // already, and swallowing them breaks two-finger gestures and momentum.
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let now = monotonicSeconds()

        if isContinuous {
            stats.withValue {
                $0.continuousEventsSeen += 1
                $0.lastScrollUptime = now
            }
            return handleContinuous(event, settings: settings)
        }
        stats.withValue { $0.lastScrollUptime = now }
        return handleWheel(event, settings: settings)
    }

    private func handleContinuous(_ event: CGEvent, settings: ScrollSettings) -> Unmanaged<CGEvent>? {
        let wantsReverse = settings.reverseContinuousDevices
            && (settings.reverseVertical || settings.reverseHorizontal)
        let wantsSmoothing = settings.affectContinuousDevices && settings.smoothingEnabled

        if wantsSmoothing {
            let dy = ScrollEventFields.vertical.read(from: event).fixedPoint
            let dx = ScrollEventFields.horizontal.read(from: event).fixedPoint
            // A non-finite delta cannot be represented by the easing state. Pass the original
            // event through untouched rather than swallowing it and poisoning the animator.
            guard dy.isFinite, dx.isFinite else { return Unmanaged.passUnretained(event) }
            guard dy != 0 || dx != 0 else { return Unmanaged.passUnretained(event) }
            // Same rule as the wheel path: never swallow what we cannot re-deliver.
            guard let target = ScrollEventPoster.target(from: event) else {
                stats.withValue { $0.wheelEventsUndeliverable += 1 }
                return Unmanaged.passUnretained(event)
            }
            let signY: Double = settings.reverseVertical ? -1 : 1
            let signX: Double = settings.reverseHorizontal ? -1 : 1
            guard animator.enqueue(
                vertical: dy * signY,
                horizontal: dx * signX,
                settings: settings,
                target: target
            ) else { return Unmanaged.passUnretained(event) }
            return nil
        }

        if wantsReverse {
            Self.flipAxes(
                of: event,
                vertical: settings.reverseVertical,
                horizontal: settings.reverseHorizontal
            )
        }
        return Unmanaged.passUnretained(event)
    }

    /// The raw magnitude to scale, picked the way Mos picks it: pixel delta first, then the
    /// fixed-point delta, then the integer line delta.
    ///
    /// Preferring the *pixel* delta is the point. It already carries the system's own scroll
    /// acceleration, so spinning the wheel fast reports a bigger number and the travel grows
    /// with it. Reading line deltas instead yields ±1 almost always, which makes every notch
    /// travel the same fixed distance no matter how fast you scroll — technically smooth,
    /// but it feels inert.
    private static func rawDelta(of event: CGEvent, axis: ScrollAxisFields) -> Double {
        axis.read(from: event).preferred
    }

    /// Which of the three delta fields actually supplied the magnitude.
    ///
    /// Worth reporting rather than assuming: if this says `line`, every notch scales from the
    /// same ±1 and fast flicks travel no further than slow ones — the pipeline is smooth but
    /// feels inert, and no amount of tuning the easing curve fixes it.
    private static func rawDeltaSource(of event: CGEvent) -> EngineStats.RawDeltaSource {
        let vertical = ScrollEventFields.vertical.read(from: event)
        let horizontal = ScrollEventFields.horizontal.read(from: event)
        if vertical.point != 0 || horizontal.point != 0 { return .point }
        if vertical.fixedPoint != 0 || horizontal.fixedPoint != 0 { return .fixed }
        return .line
    }

    private func handleWheel(_ event: CGEvent, settings: ScrollSettings) -> Unmanaged<CGEvent>? {
        let rawY = Self.rawDelta(of: event, axis: ScrollEventFields.vertical)
        let rawX = Self.rawDelta(of: event, axis: ScrollEventFields.horizontal)

        guard rawY.isFinite, rawX.isFinite else {
            stats.withValue { $0.wheelEventsPassedThrough += 1 }
            return Unmanaged.passUnretained(event)
        }
        guard rawY != 0 || rawX != 0 else { return Unmanaged.passUnretained(event) }

        let signY: Double = settings.reverseVertical ? -1 : 1
        let signX: Double = settings.reverseHorizontal ? -1 : 1

        guard settings.smoothingEnabled else {
            stats.withValue { $0.wheelEventsPassedThrough += 1 }
            // No smoothing requested: the cheapest correct thing is to flip the existing
            // event in place and let the system deliver it untouched.
            if settings.reverseVertical || settings.reverseHorizontal {
                Self.flipAxes(
                    of: event,
                    vertical: settings.reverseVertical,
                    horizontal: settings.reverseHorizontal
                )
            }
            return Unmanaged.passUnretained(event)
        }

        let gain = accelerationGain(settings: settings)
        let distanceY = settings.travel(forRawDelta: rawY) * gain * signY
        let distanceX = settings.travel(forRawDelta: rawX) * gain * signX
        guard distanceY.isFinite, distanceX.isFinite else {
            stats.withValue { $0.wheelEventsPassedThrough += 1 }
            return Unmanaged.passUnretained(event)
        }

        // Keep a copy of this event so every frame of the glide is delivered to the process
        // the notch was aimed at, instead of wherever the pointer happens to be later.
        //
        // If there is no routable target, pass the notch through untouched. Swallowing it
        // and then having nowhere to send the replacement is the one failure that presents
        // as "my scroll wheel stopped working", so the degraded path must be unsmoothed
        // scrolling, never no scrolling.
        guard let target = ScrollEventPoster.target(from: event) else {
            stats.withValue {
                $0.wheelEventsUndeliverable += 1
                $0.wheelEventsPassedThrough += 1
            }
            if settings.reverseVertical || settings.reverseHorizontal {
                Self.flipAxes(
                    of: event,
                    vertical: settings.reverseVertical,
                    horizontal: settings.reverseHorizontal
                )
            }
            return Unmanaged.passUnretained(event)
        }

        guard animator.enqueue(
            vertical: distanceY,
            horizontal: distanceX,
            settings: settings,
            target: target
        ) else {
            stats.withValue { $0.wheelEventsPassedThrough += 1 }
            return Unmanaged.passUnretained(event)
        }
        stats.withValue {
            $0.wheelEventsSmoothed += 1
            $0.lastTargetPID = Int(target.pid)
            $0.lastRawDeltaSource = Self.rawDeltaSource(of: event)
        }
        return nil
    }

    /// Rapid consecutive notches get amplified, so a long flick travels further than the
    /// same number of slow clicks. `acceleration == 1` disables this entirely.
    private func accelerationGain(settings: ScrollSettings) -> Double {
        let now = monotonicSeconds()
        defer { lastNotchTime = now }
        guard settings.acceleration > 1 else { return 1 }
        let interval = now - lastNotchTime
        let window = 0.12
        guard interval > 0, interval < window else { return 1 }
        let closeness = 1 - (interval / window)
        return 1 + (settings.acceleration - 1) * closeness
    }

    /// Negate all three representations using the one shared field/accessor definition.
    /// DeltaAxis and PointDelta are integers; FixedPtDelta is the fractional 16.16 value.
    static func flipAxes(of event: CGEvent, vertical: Bool, horizontal: Bool) {
        if vertical { ScrollEventFields.vertical.reverse(on: event) }
        if horizontal { ScrollEventFields.horizontal.reverse(on: event) }
    }

    // MARK: - Buttons

    private func handleButton(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        // Recording mode takes priority over every binding, otherwise a button already
        // mapped to Mission Control could never be recorded again.
        if let report = captureHandler.value {
            if type == .otherMouseDown {
                let modifiers = event.flags.rawValue & Self.modifierMask
                DispatchQueue.main.async { report(button, modifiers) }
            }
            return nil
        }

        guard config.value.buttonsActive else { return Unmanaged.passUnretained(event) }

        let modifiers = event.flags.rawValue & Self.modifierMask
        guard let binding = bindings.value.resolve(button: button, modifiers: modifiers) else {
            Trace.buttonUnbound(button: button)
            return Unmanaged.passUnretained(event)
        }
        let action = binding.action
        Trace.buttonSeen(button: button, isDown: type == .otherMouseDown, action: "\(action)")

        if action == .gestureNavigation {
            if type == .otherMouseDown {
                let wasIdle = gestureSessions.isEmpty
                var recognizer = MouseGestureRecognizer()
                recognizer.begin(at: event.location)
                gestureSessions[button] = recognizer
                motionEventCount = 0
                Trace.gestureBegan(button: button)
                if wasIdle { onGestureActivityChanged?(true) }
            } else if let session = gestureSessions.removeValue(forKey: button) {
                Trace.gestureEnded(
                    button: button,
                    asClick: session.shouldTreatAsClick,
                    travelled: session.maximumDistanceFromOrigin,
                    motionEvents: motionEventCount
                )
                if gestureSessions.isEmpty { onGestureActivityChanged?(false) }
                // A hold that never moved is a click, and a click on the gesture button
                // opens Mission Control.
                if session.shouldTreatAsClick {
                    stats.withValue { $0.buttonActionsFired += 1 }
                    actions.runAsync(.missionControl)
                }
            }
            return nil
        }

        // Fire on press and swallow the matching release, so the app underneath never
        // sees half a click.
        if type == .otherMouseDown {
            stats.withValue { $0.buttonActionsFired += 1 }
            actions.runAsync(action)
        }
        return nil
    }

    /// Feed pointer movement to any gesture hold in progress.
    ///
    /// The event type this arrives as is not what you would expect. Because the button-down
    /// was swallowed, the system never enters a drag for that button, so the movement is
    /// delivered as a plain `.mouseMoved` — subscribing only to `.otherMouseDragged` means
    /// never being called at all, which is how this feature managed to look implemented and
    /// do nothing. Both are accepted, and the movement is passed through untouched: the
    /// pointer belongs to the user even mid-gesture.
    private func handleMotion(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard !gestureSessions.isEmpty else { return Unmanaged.passUnretained(event) }

        // Read the delta fields with the integer accessor they are declared as, then let the
        // recognizer fall back to differencing `event.location` when they come through empty.
        let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
        let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
        let location = event.location
        Trace.motion(
            index: motionEventCount,
            type: event.type.rawValue,
            dx: dx,
            dy: dy,
            location: location
        )
        motionEventCount += 1

        // Snapshot the keys: mutating the dictionary while iterating its lazy view is not
        // something to rely on.
        for button in Array(gestureSessions.keys) {
            guard let direction = gestureSessions[button]?
                .append(location: location, fieldDeltaX: dx, fieldDeltaY: dy)
            else { continue }
            Trace.recognized(direction: direction.rawValue, action: "\(direction.action)")
            stats.withValue { $0.buttonActionsFired += 1 }
            actions.runAsync(direction.action)
        }
        return Unmanaged.passUnretained(event)
    }
}

/// Monotonic seconds since boot. Used for both the acceleration window and the
/// "last scroll seen" diagnostic, neither of which may be affected by clock changes.
@inline(__always)
func monotonicSeconds() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
