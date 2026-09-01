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
    private let runAction: (MouseAction) -> Void
    private let runGestureAction: (MouseAction) -> Void
    private let gestureOutput: any GestureNavigationOutput
    /// Kept as an explicit test/diagnostic seam for the private Dock encoder. Production gesture
    /// navigation is discrete because a direct Logi Options+ event trace showed exactly one
    /// Control+Arrow shortcut per physical hold and no Dock-swipe events.
    private let usesInteractiveGestureNavigation: Bool

    private let config: Locked<ResolvedConfig>
    private let scrollRules: ScrollRuleResolver?
    private let scrollComparison: ScrollComparisonSession?
    private let bindings = Locked<[ButtonBinding]>([])
    /// When set, button presses are reported here (with the modifiers held) and swallowed
    /// instead of being acted on, so the settings UI can record a binding from a real press.
    private let captureHandler = Locked<((Int, UInt64) -> Void)?>(nil)
    /// Buttons whose native CGEvent stream has been replaced by HID++ physical-state reports.
    /// Native events for these controls are swallowed to avoid a momentary down/up racing the
    /// real HID++ hold lifecycle.
    private let hidppOwnedButtons = Locked<Set<Int>>([])

    /// Timestamp of the last wheel notch, for the flywheel acceleration curve.
    private var lastNotchTime: CFTimeInterval = 0
    /// Axis mode of the last discrete wheel input. Switching Shift on or off must discard the
    /// other axis's residual inertia, otherwise the first horizontal notch can glide diagonally
    /// with vertical debt left from the preceding wheel spin.
    private var shiftWheelHorizontalMode = false
    private enum ButtonClaim {
        case capture
        case action(MouseAction)
    }

    /// Every swallowed down is recorded until its matching up arrives. Release handling must
    /// consult this session state, not re-resolve mutable bindings/modifiers and risk exposing a
    /// bare mouse-up to the application underneath.
    private var buttonClaims: [Int: ButtonClaim] = [:]
    private enum GestureDelivery: Equatable {
        case pending
        case interactive
        case oneShot
    }

    private struct GestureSession {
        var recognizer: MouseGestureRecognizer
        var delivery: GestureDelivery = .pending
    }

    /// Active gesture-navigation holds, keyed by button number. A dictionary rather than a
    /// single slot because two buttons can be bound to gestures and held at once.
    private var gestureSessions: [Int: GestureSession] = [:]
    /// Motion events seen in the current hold, so tracing can log the first few and stop.
    private var motionEventCount = 0

    /// Called when a gesture hold begins or ends, so the engine can bring up the motion tap
    /// only while one is in progress. Subscribing to every pointer movement permanently would
    /// burn CPU for a feature that is idle almost all of the time.
    var onGestureActivityChanged: ((Bool) -> Void)?

    init(
        config: Locked<ResolvedConfig>,
        scrollRules: ScrollRuleResolver? = nil,
        scrollComparison: ScrollComparisonSession? = nil,
        usesInteractiveGestureNavigation: Bool = false,
        gestureOutput: any GestureNavigationOutput = DockSwipeSynthesizer.shared,
        runGestureAction: @escaping (MouseAction) -> Void = {
            ActionRunner().runGestureNavigationAsync($0)
        },
        runAction: @escaping (MouseAction) -> Void = { ActionRunner().runAsync($0) }
    ) {
        self.config = config
        self.scrollRules = scrollRules
        self.scrollComparison = scrollComparison
        self.usesInteractiveGestureNavigation = usesInteractiveGestureNavigation
        self.gestureOutput = gestureOutput
        self.runGestureAction = runGestureAction
        self.runAction = runAction
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

    func updateHIDPPOwnedButtons(_ buttons: Set<Int>) {
        hidppOwnedButtons.value = buttons
    }

    /// HID++ reports physical button state directly, without a CGEvent carrying flags/location.
    /// Sample both from the current session and feed the same ownership/gesture state machine.
    func handleHIDPPButton(button: Int, isDown: Bool) {
        let modifiers = CGEventSource.flagsState(.combinedSessionState).rawValue & Self.modifierMask
        let location = CGEvent(source: nil)?.location ?? .zero
        _ = processButton(
            button: button,
            isDown: isDown,
            modifiers: modifiers,
            location: location
        )
    }

    /// Frame source in use for the current or most recent glide.
    var frameSource: DisplayLinkTicker.Source { animator.frameSource }

    func cancelInFlightScrolling() {
        animator.cancel()
        shiftWheelHorizontalMode = false
        lastNotchTime = 0
    }

    /// Drop all swallowed-button ownership. Called when a tap is stopped or disabled mid-hold,
    /// because no matching button-up can be trusted to arrive afterward.
    func cancelButtonSessions() {
        buttonClaims.removeAll()
        // The private Dock encoder is retained only behind an explicit diagnostic seam. If that
        // seam is in use, its delayed reliability resends must not outlive a tap rebuild.
        if usesInteractiveGestureNavigation { gestureOutput.cancelAll() }
        guard !gestureSessions.isEmpty else { return }
        gestureSessions.removeAll()
        onGestureActivityChanged?(false)
    }

    var activeButtonClaimCount: Int { buttonClaims.count }
    var activeGestureSessionCount: Int { gestureSessions.count }

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
        let targetPID = ScrollEventPoster.targetPID(from: event)
        let settings: ScrollSettings
        switch scrollComparison?.mode(forTargetPID: targetPID) {
        case .system:
            cancelInFlightScrolling()
            return Unmanaged.passUnretained(event)
        case let .openMouse(previewSettings):
            settings = previewSettings
        case nil:
            let resolved = resolvedScrollConfig(for: event)
            guard resolved.active else { return Unmanaged.passUnretained(event) }
            settings = resolved.scroll
        }

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


    /// Scroll rules follow the annotated process that will receive synthetic frames. Falling
    /// back to the global rule on an unknown pid is safe; applying the frontmost app's rule to
    /// a different background window is not.
    func resolvedScrollConfig(for event: CGEvent) -> ResolvedConfig {
        guard let scrollRules else { return config.value }
        return scrollRules.resolve(targetPID: ScrollEventPoster.targetPID(from: event))
    }

    struct ContinuousScrollPolicy: Equatable {
        let smooth: Bool
        let reverseVertical: Bool
        let reverseHorizontal: Bool

        var reversesAnyAxis: Bool { reverseVertical || reverseHorizontal }

        func adjusted(vertical: Double, horizontal: Double) -> (vertical: Double, horizontal: Double) {
            (
                reverseVertical ? -vertical : vertical,
                reverseHorizontal ? -horizontal : horizontal
            )
        }
    }

    static func continuousPolicy(for settings: ScrollSettings) -> ContinuousScrollPolicy {
        let reverse = settings.reverseContinuousDevices
        return ContinuousScrollPolicy(
            smooth: settings.affectContinuousDevices && settings.smoothingEnabled,
            reverseVertical: reverse && settings.reverseVertical,
            reverseHorizontal: reverse && settings.reverseHorizontal
        )
    }

    func handleContinuous(_ event: CGEvent, settings: ScrollSettings) -> Unmanaged<CGEvent>? {
        let policy = Self.continuousPolicy(for: settings)

        if policy.smooth {
            let dy = ScrollEventFields.vertical.read(from: event).fixedPoint
            let dx = ScrollEventFields.horizontal.read(from: event).fixedPoint
            // A non-finite delta cannot be represented by the easing state. Pass the original
            // event through untouched rather than swallowing it and poisoning the animator.
            guard dy.isFinite, dx.isFinite else { return Unmanaged.passUnretained(event) }
            guard dy != 0 || dx != 0 else { return Unmanaged.passUnretained(event) }
            // Same rule as the wheel path: never swallow what we cannot re-deliver.
            guard let target = ScrollEventPoster.target(from: event) else {
                stats.withValue { $0.wheelEventsUndeliverable += 1 }
                if policy.reversesAnyAxis {
                    Self.flipAxes(
                        of: event,
                        vertical: policy.reverseVertical,
                        horizontal: policy.reverseHorizontal
                    )
                }
                return Unmanaged.passUnretained(event)
            }
            let adjusted = policy.adjusted(vertical: dy, horizontal: dx)
            guard animator.enqueue(
                vertical: adjusted.vertical,
                horizontal: adjusted.horizontal,
                settings: settings,
                target: target
            ) else { return Unmanaged.passUnretained(event) }
            return nil
        }

        if policy.reversesAnyAxis {
            Self.flipAxes(
                of: event,
                vertical: policy.reverseVertical,
                horizontal: policy.reverseHorizontal
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

    struct WheelInput: Equatable {
        let vertical: Double
        let horizontal: Double
        let shiftsVerticalToHorizontal: Bool
    }

    /// Logi Options+ semantics: Shift only converts a real vertical wheel event. Trackpad-style
    /// continuous events and a physical horizontal/tilt wheel retain their native axes.
    static func wheelInput(from event: CGEvent) -> WheelInput {
        let rawVertical = rawDelta(of: event, axis: ScrollEventFields.vertical)
        let rawHorizontal = rawDelta(of: event, axis: ScrollEventFields.horizontal)
        let shiftsVerticalToHorizontal =
            event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
            && event.flags.contains(.maskShift)
            && rawVertical != 0
            && rawHorizontal == 0
        return WheelInput(
            vertical: shiftsVerticalToHorizontal ? 0 : rawVertical,
            horizontal: shiftsVerticalToHorizontal ? rawVertical : rawHorizontal,
            shiftsVerticalToHorizontal: shiftsVerticalToHorizontal
        )
    }

    /// Rewrite every representation carried by a discrete wheel event. Shift is removed after
    /// translation so browsers and NSScrollView do not see an already-horizontal event plus the
    /// modifier and translate it a second time.
    static func translateShiftWheelEvent(_ event: CGEvent, reverseHorizontal: Bool) {
        let vertical = ScrollEventFields.vertical.read(from: event)
        ScrollEventFields.horizontal.write(
            reverseHorizontal ? vertical.negated : vertical,
            on: event
        )
        ScrollEventFields.vertical.clear(on: event)
        event.flags = event.flags.subtracting(.maskShift)
    }

    private static func prepareWheelPassthrough(
        _ event: CGEvent,
        input: WheelInput,
        settings: ScrollSettings
    ) {
        if input.shiftsVerticalToHorizontal {
            translateShiftWheelEvent(event, reverseHorizontal: settings.reverseHorizontal)
        } else if settings.reverseVertical || settings.reverseHorizontal {
            flipAxes(
                of: event,
                vertical: settings.reverseVertical,
                horizontal: settings.reverseHorizontal
            )
        }
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
        let input = Self.wheelInput(from: event)
        let rawY = input.vertical
        let rawX = input.horizontal

        guard rawY.isFinite, rawX.isFinite else {
            stats.withValue { $0.wheelEventsPassedThrough += 1 }
            return Unmanaged.passUnretained(event)
        }
        guard rawY != 0 || rawX != 0 else { return Unmanaged.passUnretained(event) }

        if input.shiftsVerticalToHorizontal != shiftWheelHorizontalMode {
            animator.cancel()
            shiftWheelHorizontalMode = input.shiftsVerticalToHorizontal
        }

        let signY: Double = settings.reverseVertical ? -1 : 1
        let signX: Double = settings.reverseHorizontal ? -1 : 1

        guard settings.smoothingEnabled else {
            stats.withValue { $0.wheelEventsPassedThrough += 1 }
            // No smoothing requested: rewrite the original event in place and let the system
            // deliver it, preserving every non-scroll field and the original target.
            Self.prepareWheelPassthrough(event, input: input, settings: settings)
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
            Self.prepareWheelPassthrough(event, input: input, settings: settings)
            return Unmanaged.passUnretained(event)
        }

        if input.shiftsVerticalToHorizontal {
            // The animator rewrites point/fixed-point deltas on each frame. Preparing its event
            // template still matters for flags and for apps that inspect the line representation.
            Self.translateShiftWheelEvent(
                target.event,
                reverseHorizontal: settings.reverseHorizontal
            )
        }

        guard animator.enqueue(
            vertical: distanceY,
            horizontal: distanceX,
            settings: settings,
            target: target
        ) else {
            stats.withValue { $0.wheelEventsPassedThrough += 1 }
            Self.prepareWheelPassthrough(event, input: input, settings: settings)
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

    func handleButton(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        // Once HID++ diversion owns a control, the device's old native stream is at best a
        // duplicate and at worst the 4–20 ms fake hold that broke gesture navigation.
        guard !hidppOwnedButtons.value.contains(button) else { return nil }
        let handled = processButton(
            button: button,
            isDown: type == .otherMouseDown,
            modifiers: event.flags.rawValue & Self.modifierMask,
            location: event.location
        )
        return handled ? nil : Unmanaged.passUnretained(event)
    }

    @discardableResult
    private func processButton(
        button: Int,
        isDown: Bool,
        modifiers: UInt64,
        location: CGPoint
    ) -> Bool {
        // A swallowed down owns its matching release regardless of what changed meanwhile:
        // modifiers may have been released, bindings edited, the app disabled, or capture ended.
        if !isDown, let claim = buttonClaims.removeValue(forKey: button) {
            finishButtonClaim(claim, button: button)
            return true
        }
        guard isDown else { return false }
        // Ignore a duplicate source while the same logical button is already held.
        guard buttonClaims[button] == nil else { return true }

        // Recording mode takes priority over every binding, otherwise a button already mapped
        // to Mission Control could never be recorded again. Its release is claimed as well;
        // capture normally ends asynchronously before that release arrives.
        if let report = captureHandler.value {
            buttonClaims[button] = .capture
            DispatchQueue.main.async { report(button, modifiers) }
            return true
        }

        guard config.value.buttonsActive else { return false }
        guard let binding = bindings.value.resolve(button: button, modifiers: modifiers) else {
            Trace.buttonUnbound(button: button)
            return false
        }
        let action = binding.action
        buttonClaims[button] = .action(action)
        Trace.buttonSeen(button: button, isDown: true, action: "\(action)")

        if action == .gestureNavigation {
            let wasIdle = gestureSessions.isEmpty
            var recognizer = MouseGestureRecognizer()
            recognizer.begin(at: location)
            gestureSessions[button] = GestureSession(recognizer: recognizer)
            motionEventCount = 0
            Trace.gestureBegan(button: button)
            if wasIdle { onGestureActivityChanged?(true) }
        } else {
            stats.withValue { $0.buttonActionsFired += 1 }
            runAction(action)
        }
        return true
    }

    private func finishButtonClaim(_ claim: ButtonClaim, button: Int) {
        guard case let .action(action) = claim else { return }
        Trace.buttonSeen(button: button, isDown: false, action: "\(action)")
        guard action == .gestureNavigation,
              let session = gestureSessions.removeValue(forKey: button) else { return }

        if session.delivery == .interactive {
            gestureOutput.end(button: button, cancelled: false)
        }

        Trace.gestureEnded(
            button: button,
            asClick: session.recognizer.shouldTreatAsClick,
            travelled: session.recognizer.maximumDistanceFromOrigin,
            motionEvents: motionEventCount
        )
        if gestureSessions.isEmpty { onGestureActivityChanged?(false) }
        // A hold that never moved is a click, and a click on the gesture button opens Mission
        // Control.
        if session.recognizer.shouldTreatAsClick {
            stats.withValue { $0.buttonActionsFired += 1 }
            runAction(.missionControl)
        }
    }

    /// Feed pointer movement to any gesture hold in progress.
    ///
    /// The event type this arrives as is not what you would expect. Because the button-down
    /// was swallowed, the system never enters a drag for that button, so the movement is
    /// delivered as a plain `.mouseMoved` — subscribing only to `.otherMouseDragged` means
    /// never being called at all, which is how this feature managed to look implemented and
    /// do nothing. Both are accepted. The event itself remains untouched; production keeps the
    /// pointer associated because dissociation starves subsequent BLE mouse movement on macOS 26.
    func handleMotion(_ event: CGEvent) -> Unmanaged<CGEvent>? {
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
            guard var session = gestureSessions[button] else { continue }
            if session.delivery == .interactive, dx == 0, dy == 0 {
                // A device can stop populating its delta fields mid-hold. If its cursor remains
                // frozen, coordinate differencing cannot take over on the next sample either.
                gestureOutput.allowPointerMovement(button: button)
            }
            let update = session.recognizer.append(
                location: location,
                fieldDeltaX: dx,
                fieldDeltaY: dy
            )
            // `append` mutates the dead-zone displacement and previous location even when it
            // does not emit an update. Persist that state; otherwise 4 px + 4 px never reaches
            // the 7 px threshold and location-only devices keep differencing from stale data.
            gestureSessions[button] = session
            guard let update else { continue }

            switch update {
            case let .began(axis, pixelDelta):
                let anotherInteractiveGesture = gestureSessions.contains { otherButton, other in
                    otherButton != button && other.delivery == .interactive
                }
                if usesInteractiveGestureNavigation,
                   !anotherInteractiveGesture,
                   gestureOutput.supportsInteractiveNavigation,
                   gestureOutput.begin(
                       button: button,
                       axis: axis,
                       initialPixelDelta: pixelDelta,
                       location: location,
                       // If both fields are empty, this device is being measured from cursor
                       // coordinates. Freezing that cursor would remove its only usable signal.
                       canFreezePointer: dx != 0 || dy != 0
                   ) {
                    session.delivery = .interactive
                    Trace.interactiveGestureBegan(axis: axis.rawValue, delta: pixelDelta)
                } else {
                    // Logi Options+ emits one fixed Control+Arrow-style action on the first
                    // direction of a hold. Later movement (including reversal) is ignored until
                    // the button is physically released and pressed again.
                    let direction = axis.direction(forPixelDelta: pixelDelta)
                    session.delivery = .oneShot
                    Trace.recognized(direction: direction.rawValue, action: "\(direction.action)")
                    runGestureAction(direction.action)
                }
                stats.withValue { $0.buttonActionsFired += 1 }

            case let .changed(_, pixelDelta):
                if session.delivery == .interactive {
                    gestureOutput.change(button: button, pixelDelta: pixelDelta)
                }
            }
            gestureSessions[button] = session
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
