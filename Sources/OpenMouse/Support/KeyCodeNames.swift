import AppKit
import Carbon.HIToolbox

/// Human-readable names for virtual key codes, plus modifier glyphs, so a recorded
/// shortcut can be rendered the way macOS renders it in menus.
enum KeyCodeNames {
    /// Names for keys that do not produce a printable character. Printable keys are resolved
    /// from the active layout by `KeyboardLayout.character(for:)`; an ANSI key-code table would
    /// label the physical position rather than what that position means to this user.
    private static let table: [UInt16: String] = [
        UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "空格",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12"
    ]

    static func name(for keyCode: UInt16) -> String {
        name(for: keyCode, resolveCharacter: KeyboardLayout.character(for:))
    }

    static func name(
        for keyCode: UInt16,
        resolveCharacter: (UInt16) -> Character?
    ) -> String {
        if let fixedName = table[keyCode] { return fixedName }
        if let character = resolveCharacter(keyCode) {
            return String(character).uppercased()
        }
        return "键 \(keyCode)"
    }

    /// ⌃⌥⇧⌘ in Apple's canonical order.
    static func modifierGlyphs(_ rawFlags: UInt64) -> String {
        let flags = CGEventFlags(rawValue: rawFlags)
        var out = ""
        if flags.contains(.maskSecondaryFn) { out += "fn" }
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskShift) { out += "⇧" }
        if flags.contains(.maskCommand) { out += "⌘" }
        return out
    }

    static func describe(_ combo: KeyCombo) -> String {
        modifierGlyphs(combo.modifiers) + name(for: combo.keyCode)
    }
}
