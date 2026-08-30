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
    private let poster = ScrollEventPoster()
    private let actions = ActionRunner()

    private let config: Locked<ResolvedConfig>
    private let bindings = Locked<[ButtonBinding]>([])
    /// When set, button presses are reported here (with the modifiers held) and swallowed
    /// instead of being acted on, so the settings UI can record a binding from a real press.
    private let captureHandler = Locked<((Int, UInt64) -> Void)?>(nil)

    /// Timestamp of the last wheel notch, for the flywheel acceleration curve.
    private var lastNotchTime: CFTimeInterval = 0
    /// Which button (if any) is currently held for drag-to-scroll.
    private var dragScrollButton: Int?
    /// Active gesture-navigation holds, keyed by button number. A dictionary rather than a
    /// single slot because two buttons can be bound to gestures and held at once.
    private var gestureSessions: [Int: MouseGestureRecognizer] = [:]

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

    /// True when any binding needs mouse-drag events, so the tap can widen its mask.
    /// Both drag-scrolling and gesture navigation are driven by pointer movement.
    static func needsDragEvents(_ list: [ButtonBinding]) -> Bool {
        list.contains { $0.isActive && ($0.action == .dragScroll || $0.action == .gestureNavigation) }
    }

    /// Frame source in use for the current or most recent glide.
    var frameSource: DisplayLinkTicker.Source { animator.frameSource }

    func cancelInFlightScrolling() {
        animator.cancel()
    }

    // MARK: - Entry point

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Anything we posted ourselves must never be reprocessed, or a single notch would
        // feed back into the animator forever.
        if event.getIntegerValueField(.eventSourceUserData) == ScrollEventPoster.Tag.magic {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .scrollWheel:
            return handleScroll(event)
        case .otherMouseDown, .otherMouseUp:
            return handleButton(type: type, event: event)
        case .otherMouseDragged:
            return handleDrag(event)
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
            let dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            guard dy != 0 || dx != 0 else { return Unmanaged.passUnretained(event) }
            let signY: Double = settings.reverseVertical ? -1 : 1
            let signX: Double = settings.reverseHorizontal ? -1 : 1
            animator.enqueue(
                vertical: dy * signY,
                horizontal: dx * signX,
                settings: settings,
                target: ScrollEventPoster.target(from: event)
            )
            return nil
        }

        if wantsReverse {
            flipAxes(
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
    private static func rawDelta(of event: CGEvent, pointField: CGEventField,
                                 fixedField: CGEventField, lineField: CGEventField) -> Double {
        let point = event.getDoubleValueField(pointField)
        if point != 0 { return point }
        let fixed = event.getDoubleValueField(fixedField)
        if fixed != 0 { return fixed }
        return event.getDoubleValueField(lineField)
    }

    private func handleWheel(_ event: CGEvent, settings: ScrollSettings) -> Unmanaged<CGEvent>? {
        let rawY = Self.rawDelta(
            of: event,
            pointField: .scrollWheelEventPointDeltaAxis1,
            fixedField: .scrollWheelEventFixedPtDeltaAxis1,
            lineField: .scrollWheelEventDeltaAxis1
        )
        let rawX = Self.rawDelta(
            of: event,
            pointField: .scrollWheelEventPointDeltaAxis2,
            fixedField: .scrollWheelEventFixedPtDeltaAxis2,
            lineField: .scrollWheelEventDeltaAxis2
        )

        guard rawY != 0 || rawX != 0 else { return Unmanaged.passUnretained(event) }

        let signY: Double = settings.reverseVertical ? -1 : 1
        let signX: Double = settings.reverseHorizontal ? -1 : 1

        guard settings.smoothingEnabled else {
            stats.withValue { $0.wheelEventsPassedThrough += 1 }
            // No smoothing requested: the cheapest correct thing is to flip the existing
            // event in place and let the system deliver it untouched.
            if settings.reverseVertical || settings.reverseHorizontal {
                flipAxes(
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
        stats.withValue { $0.wheelEventsSmoothed += 1 }
        // Keep a copy of this event so every frame of the glide is delivered to the process
        // the notch was aimed at, instead of wherever the pointer happens to be later.
        animator.enqueue(
            vertical: distanceY,
            horizontal: distanceX,
            settings: settings,
            target: ScrollEventPoster.target(from: event)
        )
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

    /// Negate every delta representation the event carries. Missing any one of the three
    /// leaves apps reading a different field scrolling the wrong way.
    ///
    /// The line and point deltas are integer fields and the fixed-point ones are doubles;
    /// each is read back with the matching accessor so nothing is silently truncated.
    private func flipAxes(of event: CGEvent, vertical: Bool, horizontal: Bool) {
        if vertical {
            event.setIntegerValueField(
                .scrollWheelEventDeltaAxis1,
                value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            )
            event.setIntegerValueField(
                .scrollWheelEventPointDeltaAxis1,
                value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            )
            event.setDoubleValueField(
                .scrollWheelEventFixedPtDeltaAxis1,
                value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            )
        }
        if horizontal {
            event.setIntegerValueField(
                .scrollWheelEventDeltaAxis2,
                value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            )
            event.setIntegerValueField(
                .scrollWheelEventPointDeltaAxis2,
                value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            )
            event.setDoubleValueField(
                .scrollWheelEventFixedPtDeltaAxis2,
                value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            )
        }
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
            return Unmanaged.passUnretained(event)
        }
        let action = binding.action

        if action == .dragScroll {
            if type == .otherMouseDown {
                dragScrollButton = button
            } else if dragScrollButton == button {
                dragScrollButton = nil
            }
            return nil
        }

        if action == .gestureNavigation {
            if type == .otherMouseDown {
                gestureSessions[button] = MouseGestureRecognizer()
            } else if let session = gestureSessions.removeValue(forKey: button) {
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

    private func handleDrag(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        if gestureSessions[button] != nil {
            let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            if let direction = gestureSessions[button]?.append(deltaX: dx, deltaY: dy) {
                stats.withValue { $0.buttonActionsFired += 1 }
                actions.runAsync(direction.action)
            }
            // Swallow the movement so the pointer stays put during the gesture.
            return nil
        }

        guard let held = dragScrollButton, button == held
        else { return Unmanaged.passUnretained(event) }

        let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
        let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
        // 1:1 with the hand, no easing — drag scrolling should feel like grabbing paper.
        if dy != 0 || dx != 0 {
            poster.post(
                vertical: dy,
                horizontal: dx,
                phase: .none,
                target: ScrollEventPoster.target(from: event)
            )
        }
        // Swallowing the drag keeps the pointer anchored while scrolling.
        return nil
    }
}

/// Monotonic seconds since boot. Used for both the acceleration window and the
/// "last scroll seen" diagnostic, neither of which may be affected by clock changes.
@inline(__always)
func monotonicSeconds() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
