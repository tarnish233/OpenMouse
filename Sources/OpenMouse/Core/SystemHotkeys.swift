import CoreGraphics
import Foundation

/// The key strokes macOS itself uses for its window-management shortcuts, read from the
/// system's own configuration rather than guessed.
///
/// Hardcoding these was a mistake worth naming. A synthesised window-management shortcut has
/// to match what the WindowServer is listening for *exactly* — and the part that is easy to
/// miss is the `Fn` bit, which every one of them carries. Get it wrong and nothing fails:
/// the keystroke posts successfully, the system ignores it, and the feature silently does
/// nothing. Reading `com.apple.symbolichotkeys` also means a user who remapped Mission
/// Control still gets Mission Control, and one who *disabled* it gets told so instead of
/// being left wondering.
///
/// Mos reads the same domain for its Spaces shortcuts; this covers a few more IDs.
enum SystemHotkeys {
    /// `AppleSymbolicHotKeys` entry IDs, as used by System Settings › Keyboard › Shortcuts.
    ///
    /// Anything the system owns belongs in here rather than in a literal somewhere. Every one
    /// of these was a candidate for the same silent failure: a plausible-looking key
    /// combination that the WindowServer simply does not act on.
    enum Symbolic: Int, CaseIterable {
        case cycleWindows = 27
        case screenshotToFile = 28
        case screenshotSelection = 30
        case missionControl = 32
        case applicationWindows = 33
        case showDesktop = 36
        case toggleDock = 52
        case nextInputSource = 61
        case spotlight = 64
        case spotlightWindow = 65
        case spaceLeft = 79
        case spaceRight = 81
        case screenshotOptions = 184
        case quickNote = 190

        /// The window-management shortcuts, which all carry `Fn`. Kept as a set because that
        /// shared property is exactly what got missed and is worth asserting on.
        static let windowManagement: Set<Symbolic> = [
            .missionControl, .applicationWindows, .showDesktop, .spaceLeft, .spaceRight
        ]
    }

    struct Stroke: Equatable {
        var keyCode: UInt16
        var flags: CGEventFlags
    }

    /// What macOS ships with, used when the domain has no entry for an ID — an untouched
    /// system often has no plist entry at all, which is not the same as "disabled".
    ///
    /// `Fn` (`maskSecondaryFn`) on every one of them is not decoration: it is what separates
    /// "Control-Left" from "move one space left".
    static let defaults: [Symbolic: Stroke] = [
        .cycleWindows: Stroke(keyCode: 50, flags: .maskCommand),
        .screenshotToFile: Stroke(keyCode: 20, flags: [.maskShift, .maskCommand]),
        .screenshotSelection: Stroke(keyCode: 21, flags: [.maskShift, .maskCommand]),
        .missionControl: Stroke(keyCode: 126, flags: [.maskControl, .maskSecondaryFn]),
        .applicationWindows: Stroke(keyCode: 125, flags: [.maskControl, .maskSecondaryFn]),
        .showDesktop: Stroke(keyCode: 103, flags: .maskSecondaryFn),
        .toggleDock: Stroke(keyCode: 2, flags: [.maskAlternate, .maskCommand]),
        .nextInputSource: Stroke(keyCode: 49, flags: [.maskControl, .maskAlternate]),
        .spotlight: Stroke(keyCode: 49, flags: .maskCommand),
        .spotlightWindow: Stroke(keyCode: 49, flags: [.maskAlternate, .maskCommand]),
        .spaceLeft: Stroke(keyCode: 123, flags: [.maskControl, .maskSecondaryFn]),
        .spaceRight: Stroke(keyCode: 124, flags: [.maskControl, .maskSecondaryFn]),
        .screenshotOptions: Stroke(keyCode: 23, flags: [.maskShift, .maskCommand]),
        .quickNote: Stroke(keyCode: 12, flags: .maskSecondaryFn)
    ]

    /// Keys on the function row that the system handles directly, with no
    /// `AppleSymbolicHotKeys` entry to read.
    ///
    /// These are not guesses and not copied from a table — each was posted on macOS 26.6 and
    /// confirmed by the system's own log. Mos's identifiers for two of them are misleading
    /// (`appExpose` is labelled 启动台 in its UI, and 131 in fact opens Spotlight's app
    /// browser), which is exactly why the evidence is recorded next to the value.
    enum FunctionKey: String, CaseIterable {
        /// Dock logs `Sending .launchAppsBrowsing` and a 聚焦 window appears. This is what
        /// replaced Launchpad in macOS 26; `Launchpad.app` no longer exists.
        case appBrowser
        /// Dock logs `Changing from mode .none to .showAllWindows`.
        case missionControl
        /// A 控制中心 window appears.
        case controlCenter

        var stroke: Stroke {
            switch self {
            case .appBrowser: Stroke(keyCode: 131, flags: .maskSecondaryFn)
            case .missionControl: Stroke(keyCode: 160, flags: .maskSecondaryFn)
            case .controlCenter: Stroke(keyCode: 178, flags: .maskSecondaryFn)
            }
        }
    }

    /// Outcome of resolving one shortcut, so a disabled shortcut is distinguishable from a
    /// working one. "Nothing happened" needs a reason attached to it.
    enum Resolution: Equatable {
        case stroke(Stroke)
        /// The user switched this shortcut off in System Settings. Posting the default would
        /// do nothing, so say so rather than pretending to act.
        case disabledBySystem
    }

    private static let cache = Locked<[Symbolic: Resolution]>([:])

    static func resolve(_ hotkey: Symbolic) -> Resolution {
        if let cached = cache.withValue({ $0[hotkey] }) { return cached }
        let resolution = read(hotkey) ?? .stroke(defaults[hotkey]!)
        cache.withValue { $0[hotkey] = resolution }
        return resolution
    }

    /// Forget what was read, so a shortcut changed in System Settings takes effect without a
    /// relaunch.
    static func invalidate() {
        cache.withValue { $0.removeAll() }
    }

    /// `nil` means "no opinion recorded" — fall back to the shipped default.
    private static func read(_ hotkey: Symbolic) -> Resolution? {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let hotkeys = domain["AppleSymbolicHotKeys"] as? [String: Any],
              let entry = hotkeys[String(hotkey.rawValue)] as? [String: Any]
        else { return nil }

        return resolution(from: entry)
    }

    /// Parse one user-writable plist entry without trapping on negative or oversized numbers.
    /// Structural damage means "no opinion" (fall back to the shipped default); a present but
    /// unrepresentable shortcut is disabled rather than guessed.
    static func resolution(from entry: [String: Any]) -> Resolution? {
        if let enabled = entry["enabled"] as? Bool, !enabled {
            return .disabledBySystem
        }

        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCode = parameters[1] as? Int,
              let modifiers = parameters[2] as? Int
        else { return nil }

        // UInt16.max is the placeholder for "no key", which is how a shortcut with nothing
        // bound to it is recorded. Any other unrepresentable user-edited value is equally
        // unusable and must not be allowed to trap during narrowing.
        guard keyCode != Int(UInt16.max),
              let narrowedKeyCode = UInt16(exactly: keyCode),
              let rawModifiers = UInt64(exactly: modifiers)
        else { return .disabledBySystem }

        return .stroke(Stroke(
            keyCode: narrowedKeyCode,
            flags: CGEventFlags(rawValue: rawModifiers)
        ))
    }
}
