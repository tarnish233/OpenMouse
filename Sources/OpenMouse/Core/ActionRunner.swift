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

    init() {
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
        /// Desktop switches, which must be paced: the system *discards* one requested while a
        /// space transition is animating.
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
        case .passthrough, .gestureNavigation:
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
        perform(.systemHotkey(hotkey), describing: action)
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
            keyStroke(combo.keyCode, flags: CGEventFlags(rawValue: combo.modifiers))
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
