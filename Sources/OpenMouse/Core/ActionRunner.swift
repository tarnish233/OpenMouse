import AppKit
import CoreGraphics

/// Carries out the action bound to a mouse button.
///
/// Everything is expressed as a synthetic keystroke rather than a private API: the window
/// manager, Spaces and navigation all have real shortcuts, and posting keys keeps the app free
/// of anything that breaks on the next macOS release.
///
/// The whole mapping lives in one exhaustive `switch` (`stroke(for:)`) for a specific reason.
/// Twice in this app's history an action existed in the picker and silently did nothing — once
/// because the key code was invented, once because the `Fn` bit was missing. An exhaustive
/// switch makes the compiler refuse to build when an action has no implementation, which turns
/// that class of bug from "ships and nobody notices" into "does not compile".
struct ActionRunner {
    private let source: CGEventSource?
    /// Self-check seam for proving an unset custom shortcut never reaches the posting edge.
    private let customKeyStroke: ((UInt16, CGEventFlags) -> Void)?

    init(customKeyStroke: ((UInt16, CGEventFlags) -> Void)? = nil) {
        self.customKeyStroke = customKeyStroke
        source = CGEventSource(stateID: .hidSystemState)
        source?.userData = SyntheticEventTag.magic
    }

    /// How an action gets performed.
    enum Stroke: Equatable {
        /// A shortcut written as the character it is. The key *code* is resolved from the live
        /// keyboard layout, because a code is a physical position: the position of `W` types
        /// `Z` on French AZERTY and `,` on Dvorak, so a hardcoded code sends the wrong
        /// shortcut rather than none at all.
        case character(Character, CGEventFlags)
        /// A key that types nothing: arrows, delete, escape, tab, space.
        case key(UInt16, CGEventFlags)
        /// Like `key`, but the modifiers are pressed as real `flagsChanged` events around the
        /// keystroke instead of merely being set as flags on it.
        ///
        /// The app switcher needs this and nothing else works: ⌘⇥ posted as a flagged key
        /// event is ignored outright, whether the flags are dropped or held on key-up. Sending
        /// the ⌘ key itself first makes the system's modifier state agree, and then the switch
        /// happens. Verified by watching the frontmost application actually change.
        case held(UInt16, CGEventFlags)
        /// Read from `com.apple.symbolichotkeys`, so a remapped or disabled shortcut is
        /// honoured rather than guessed at.
        case systemHotkey(SystemHotkeys.Symbolic)
        /// A function-row key the system handles directly, with no configurable entry.
        case functionKey(SystemHotkeys.FunctionKey)
        /// Media and volume keys, which are not key codes at all.
        case aux(AuxKey)
        /// Direct desktop-switch actions selected as ordinary button bindings retain the legacy
        /// queue. Gesture navigation deliberately bypasses it: a Logi Options+ trace on
        /// 2026-08-31 showed one immediate Control+Arrow stroke per physical hold, including
        /// when a previous Space animation was still running.
        case paced
        case custom(KeyCombo)
        case launch(String)
        /// Handled elsewhere in the pipeline, not by posting anything.
        case handledElsewhere
    }

    /// `NX_KEYTYPE_*` identifiers. Hardware constants — not key codes, not layout-dependent.
    enum AuxKey: Int32 {
        case soundUp = 0
        case soundDown = 1
        case mute = 7
        case play = 16
        case next = 17
        case previous = 18
    }

    /// Key codes for keys that type nothing, so there is no character to resolve.
    private enum Key {
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
    }

    // MARK: - The mapping

    /// Exhaustive by design: adding a `MouseAction` without a stroke here will not compile.
    static func stroke(for action: MouseAction) -> Stroke {
        switch action {
        case .passthrough, .gestureNavigation, .toggleDPI:
            .handledElsewhere

        // Window management, taken from the system's own shortcut configuration.
        case .missionControl: .systemHotkey(.missionControl)
        case .applicationWindows: .systemHotkey(.applicationWindows)
        case .showDesktop: .systemHotkey(.showDesktop)
        case .cycleWindows: .systemHotkey(.cycleWindows)
        case .toggleDock: .systemHotkey(.toggleDock)
        case .spaceLeft, .spaceRight: .paced

        // Function-row keys the system owns outright.
        case .appBrowser: .functionKey(.appBrowser)
        case .controlCenter: .functionKey(.controlCenter)

        // Other configurable system shortcuts.
        case .spotlight: .systemHotkey(.spotlight)
        case .nextInputSource: .systemHotkey(.nextInputSource)
        case .quickNote: .systemHotkey(.quickNote)
        case .screenshotToFile: .systemHotkey(.screenshotToFile)
        case .screenshotSelection: .systemHotkey(.screenshotSelection)
        case .screenshotOptions: .systemHotkey(.screenshotOptions)

        // App switcher: needs the ⌘ key itself pressed, not just the flag set.
        case .switchApp: .held(Key.tab, .maskCommand)
        case .switchAppReverse: .held(Key.tab, [.maskCommand, .maskShift])

        // Windows.
        case .minimizeWindow: .character("m", .maskCommand)
        case .hideApplication: .character("h", .maskCommand)
        case .hideOthers: .character("h", [.maskCommand, .maskAlternate])
        case .closeAllWindows: .character("w", [.maskCommand, .maskAlternate])
        case .quitApp: .character("q", .maskCommand)

        // Navigation and editing.
        case .navigateBack: .character("[", .maskCommand)
        case .navigateForward: .character("]", .maskCommand)
        case .newTab: .character("t", .maskCommand)
        case .closeTab: .character("w", .maskCommand)
        case .nextTab: .key(Key.rightArrow, [.maskCommand, .maskShift])
        case .previousTab: .key(Key.leftArrow, [.maskCommand, .maskShift])
        case .copy: .character("c", .maskCommand)
        case .paste: .character("v", .maskCommand)
        case .cut: .character("x", .maskCommand)
        case .undo: .character("z", .maskCommand)
        case .redo: .character("z", [.maskCommand, .maskShift])
        case .selectAll: .character("a", .maskCommand)
        case .find: .character("f", .maskCommand)
        case .zoomIn: .character("=", .maskCommand)
        case .zoomOut: .character("-", .maskCommand)

        // Files.
        case .newFinderWindow: .character("n", .maskCommand)
        case .newFolder: .character("n", [.maskCommand, .maskShift])
        case .moveToTrash: .key(Key.delete, .maskCommand)
        case .emptyTrash: .key(Key.delete, [.maskCommand, .maskShift])
        case .duplicateFile: .character("d", .maskCommand)
        case .getInfo: .character("i", .maskCommand)
        case .goToFolder: .character("g", [.maskCommand, .maskShift])
        case .viewAsIcons: .character("1", .maskCommand)
        case .viewAsList: .character("2", .maskCommand)
        case .viewAsColumns: .character("3", .maskCommand)
        case .viewAsGallery: .character("4", .maskCommand)

        // System.
        case .escapeKey: .key(Key.escape, [])
        case .forceQuit: .key(Key.escape, [.maskCommand, .maskAlternate])
        case .characterViewer: .key(Key.space, [.maskControl, .maskCommand])
        case .lockScreen: .character("q", [.maskControl, .maskCommand])
        case .logout: .character("q", [.maskCommand, .maskShift])
        case .invertColors: .character("8", [.maskCommand, .maskAlternate, .maskControl])

        // Media.
        case .playPause: .aux(.play)
        case .nextTrack: .aux(.next)
        case .previousTrack: .aux(.previous)
        case .volumeUp: .aux(.soundUp)
        case .volumeDown: .aux(.soundDown)
        case .mute: .aux(.mute)

        case let .keyStroke(combo): .custom(combo)
        case let .launchApp(path): .launch(path)
        }
    }

    // MARK: - Dispatch

    /// Actions are dispatched off the event-tap callback rather than executed inside it.
    /// Posting a synthetic keystroke re-enters the event pipeline, and a tap callback that
    /// takes too long gets disabled by the system — the deferral keeps both problems away.
    func runAsync(_ action: MouseAction) {
        DispatchQueue.main.async { self.run(action) }
    }

    /// Match Logi Options+' gesture-button delivery rather than the separately bound desktop
    /// actions: the first direction recognised in each physical hold posts immediately, without
    /// waiting behind `SpaceSwitchPacer`. Re-pressing during an in-flight animation therefore
    /// sends a fresh Control+Arrow stroke right away.
    func runGestureNavigationAsync(_ action: MouseAction) {
        DispatchQueue.main.async { self.runGestureNavigation(action) }
    }

    func runGestureNavigation(_ action: MouseAction) {
        switch action {
        case .spaceLeft, .spaceRight:
            MainActor.assumeIsolated { SpaceSwitchPacer.shared.cancel() }
            postWithoutPacing(action)
        default:
            run(action)
        }
    }

    func run(_ action: MouseAction) {
        let stroke = Self.stroke(for: action)
        if stroke == .paced {
            MainActor.assumeIsolated { SpaceSwitchPacer.shared.request(action) }
            return
        }
        perform(stroke, describing: action)
    }

    /// Perform a paced action for real, without re-entering the pacer.
    func postWithoutPacing(_ action: MouseAction) {
        guard Self.stroke(for: action) == .paced else { return }
        let hotkey: SystemHotkeys.Symbolic = action == .spaceLeft ? .spaceLeft : .spaceRight
        guard case let .stroke(stroke) = SystemHotkeys.resolve(hotkey) else {
            Trace.actionUnavailable(
                action: "\(action)",
                reason: "系统快捷键已在「系统设置 › 键盘 › 快捷键」中被关闭"
            )
            return
        }
        gestureSpaceKeyStroke(stroke.keyCode, flags: stroke.flags)
    }

    private func perform(_ stroke: Stroke, describing action: MouseAction) {
        switch stroke {
        case .handledElsewhere, .paced:
            break
        case let .character(character, flags):
            guard let keyCode = KeyboardLayout.keyCode(for: character) else {
                Trace.actionUnavailable(
                    action: "\(action)",
                    reason: "当前键盘布局和 ANSI 兜底都无法解析字符 \(character)"
                )
                return
            }
            keyStroke(keyCode, flags: flags)
        case let .key(code, flags):
            keyStroke(code, flags: flags)
        case let .held(code, flags):
            keyStrokeWithRealModifiers(code, flags: flags)
        case let .functionKey(key):
            keyStroke(key.stroke.keyCode, flags: key.stroke.flags)
        case let .systemHotkey(hotkey):
            postSystemHotkey(hotkey, describing: action)
        case let .aux(key):
            auxKeyStroke(key)
        case let .custom(combo):
            guard combo.isSet else {
                Trace.actionUnavailable(action: "\(action)", reason: "自定义快捷键尚未录入")
                return
            }
            let flags = CGEventFlags(rawValue: combo.modifiers)
            if let customKeyStroke {
                customKeyStroke(combo.keyCode, flags)
            } else {
                keyStroke(combo.keyCode, flags: flags)
            }
        case let .launch(path):
            openApp(at: path)
        }
    }

    private func postSystemHotkey(_ hotkey: SystemHotkeys.Symbolic, describing action: MouseAction) {
        if case let .stroke(stroke) = SystemHotkeys.resolve(hotkey) {
            keyStroke(stroke.keyCode, flags: stroke.flags)
            return
        }
        if let fallback = Self.fallbackHotkey(for: hotkey),
           case let .stroke(stroke) = SystemHotkeys.resolve(fallback) {
            keyStroke(stroke.keyCode, flags: stroke.flags)
            return
        }
        // Silence with a reason beats silence.
        Trace.actionUnavailable(
            action: "\(action)",
            reason: "系统快捷键已在「系统设置 › 键盘 › 快捷键」中被关闭"
        )
    }

    /// Which symbolic-hotkey entry an action reads, for the checks and diagnostics.
    static func symbolicHotkey(for action: MouseAction) -> SystemHotkeys.Symbolic? {
        if case let .systemHotkey(hotkey) = stroke(for: action) { return hotkey }
        if action == .spaceLeft { return .spaceLeft }
        if action == .spaceRight { return .spaceRight }
        return nil
    }

    /// Which function-row key an action posts, for the checks and diagnostics.
    static func functionKey(for action: MouseAction) -> SystemHotkeys.FunctionKey? {
        if case let .functionKey(key) = stroke(for: action) { return key }
        return nil
    }

    /// Where to look next when the primary shortcut is switched off. Only for cases where a
    /// second entry genuinely does the same job — Spotlight's search field and its window are
    /// both "open the launcher", and a machine where a third-party launcher has taken over
    /// ⌘Space usually still answers on the other one.
    static func fallbackHotkey(for hotkey: SystemHotkeys.Symbolic) -> SystemHotkeys.Symbolic? {
        hotkey == .spotlight ? .spotlightWindow : nil
    }

    // MARK: - Primitives

    /// Virtual key codes of the modifier keys themselves, for `keyStrokeWithRealModifiers`.
    private static let modifierKeyCodes: [(CGEventFlags, UInt16)] = [
        (.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59)
    ]

    /// Press the modifiers as actual key events, then the key, then release them.
    ///
    /// Needed only where setting `flags` is not enough. The app switcher is the case: it reads
    /// the system's modifier state rather than the event's flags, so a flagged ⌘⇥ does nothing
    /// at all until the ⌘ key itself has been seen going down.
    private func keyStrokeWithRealModifiers(_ keyCode: UInt16, flags: CGEventFlags) {
        let modifiers = Self.modifierKeyCodes.filter { flags.contains($0.0) }

        var accumulated: CGEventFlags = []
        for (flag, code) in modifiers {
            accumulated.insert(flag)
            postModifier(code, flags: accumulated, isDown: true)
        }
        keyStroke(keyCode, flags: flags)
        for (flag, code) in modifiers.reversed() {
            accumulated.remove(flag)
            postModifier(code, flags: accumulated, isDown: false)
        }
    }

    private func postModifier(_ keyCode: UInt16, flags: CGEventFlags, isDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
        else { return }
        event.type = .flagsChanged
        event.flags = flags
        SyntheticEventTag.mark(event)
        event.post(tap: .cghidEventTap)
    }

    private func keyStroke(_ keyCode: UInt16, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = []
        SyntheticEventTag.mark(down)
        SyntheticEventTag.mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Reproduce the event shape captured from `logioptionsplus_agent` for desktop gestures:
    /// Control+Fn+Arrow down, Fn+Arrow up, then a flags-changed edge that clears Fn. The system
    /// reacts to the first edge; preserving the full sequence avoids leaving synthetic modifier
    /// state behind and makes a second physical hold valid during the first Space animation.
    /// When each event goes out is `gestureSpaceEventDelays`, not this builder's concern.
    static func gestureSpaceEvents(
        keyCode: UInt16,
        flags: CGEventFlags,
        source: CGEventSource?
    ) -> [CGEvent]? {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
              let clear = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return nil }
        down.flags = flags
        up.flags = flags.intersection(.maskSecondaryFn)
        clear.type = .flagsChanged
        clear.flags = []
        for event in [down, up, clear] { SyntheticEventTag.mark(event) }
        return [down, up, clear]
    }

    /// How long the arrow stays down in a desktop-switch stroke.
    ///
    /// 2026-10-20, macOS 27.0.1: `logioptionsplus_agent` (Logi Options+ 2.9) posted exactly the
    /// three events of `gestureSpaceEvents`, but with key-up a median 14 ms after key-down (31
    /// strokes seen by a session tap, 2–84 ms with delivery jitter) and the flags clear about
    /// 1 ms after that; its `virtual_input_osx::send_hid_keyboard` calls `usleep(10000)` between
    /// the two edges. The 2026-08-31 trace that defined the shape did not record timing, so this
    /// app posted all three back to back — a key press no physical key can produce. No failure
    /// was traced to that: every unanswered request in the 2026-10-19 session was the last Space
    /// on its display or an open App Exposé. It is an avoidable difference from the reference
    /// implementation, and removing it costs one 10 ms sleep on a queue nobody waits for.
    static let gestureSpaceKeyHold: TimeInterval = 0.010

    /// Delay before each event of `gestureSpaceEvents`: key-down at once, key-up after the hold,
    /// the flags clear straight after the key-up.
    static let gestureSpaceEventDelays: [TimeInterval] = [0, gestureSpaceKeyHold, 0]

    /// The hold must never run on the main thread: both event taps and the gesture motion tap
    /// are served by the main run loop, and constraint 12 exists because a stalled callback gets
    /// the tap disabled. Serial, so a stroke is atomic — a second stroke's key-down can never land
    /// between the first one's key-down and key-up.
    private static let gestureSpaceQueue = DispatchQueue(
        label: "com.openmouse.OpenMouse.gesture-space-stroke",
        qos: .userInteractive
    )

    /// Post one desktop-switch stroke asynchronously with `gestureSpaceEventDelays`. The queue
    /// and posting edge are injectable so the self-check can prove ordering, the hold, and that
    /// nothing is posted on the caller's thread.
    static func deliverGestureSpaceEvents(
        _ events: [CGEvent],
        on queue: DispatchQueue = gestureSpaceQueue,
        post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) {
        let delays = gestureSpaceEventDelays
        queue.async {
            for (index, event) in events.enumerated() {
                // An event beyond the delay table still goes out; never drop a key-up.
                let delay = index < delays.count ? delays[index] : 0
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                post(event)
            }
        }
    }

    /// Let an in-flight stroke finish before the process exits, so a quit can never land
    /// between a key-down and its key-up. Waits for at most one hold.
    static func flushPendingGestureSpaceStrokes() {
        gestureSpaceQueue.sync {}
    }

    private func gestureSpaceKeyStroke(_ keyCode: UInt16, flags: CGEventFlags) {
        guard let events = Self.gestureSpaceEvents(
            keyCode: keyCode,
            flags: flags,
            source: source
        ) else { return }
        Self.deliverGestureSpaceEvents(events)
    }

    /// Build one media-key edge without posting it, so the marker invariant is testable.
    static func auxiliaryEvent(_ key: AuxKey, isDown: Bool) -> CGEvent? {
        let state = isDown ? 0x0A : 0x0B
        let data1 = (Int(key.rawValue) << 16) | (state << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: data1,
            data2: -1
        )?.cgEvent else { return nil }
        SyntheticEventTag.mark(event)
        return event
    }

    /// Media keys are not virtual key codes; they travel as `NSSystemDefined` events with
    /// the key identifier and press state packed into `data1`.
    private func auxKeyStroke(_ key: AuxKey) {
        for isDown in [true, false] {
            Self.auxiliaryEvent(key, isDown: isDown)?.post(tap: .cghidEventTap)
        }
    }

    private func openApp(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
