import Carbon
import Foundation

/// Resolves a character to the virtual key code that produces it *on the layout in use*.
///
/// A virtual key code names a physical position, not a letter. `kVK_ANSI_C` is only "C" on a
/// US-style layout: on Dvorak that position is `J`, and on French AZERTY the position of `W`
/// is `Z`. Hardcoding the ANSI codes therefore does not merely fail on those layouts, it sends
/// the *wrong shortcut* — "close tab" becomes ⌘Z (undo) for a French user and ⌘, (open
/// preferences) for a Dvorak one. Silent, and destructive rather than inert.
///
/// So the mapping is read from the active input source instead of assumed. When the active
/// source is an input method with no layout of its own (a Pinyin or Kana IME, say), the API
/// hands back the keyboard layout underneath it, which is the one that matters here.
enum KeyboardLayout {
    /// ANSI/QWERTY positions, used only when the live layout cannot answer.
    ///
    /// Not a preference — a last resort. A layout where a character needs a modifier to type
    /// has no unmodified key code for it, and sending the ANSI position is more likely to be
    /// right than sending nothing.
    static let ansiFallback: [Character: UInt16] = [
        "c": 8, "v": 9, "w": 13, "t": 17, "q": 12,
        "[": 33, "]": 30, "-": 27, "=": 24
    ]

    private static let cache = Locked<[Character: UInt16]?>(nil)

    /// The key code that types `character` right now, or the ANSI position if unknowable.
    static func keyCode(for character: Character) -> UInt16 {
        if let mapped = table()[character] { return mapped }
        return ansiFallback[character] ?? 0
    }

    /// Whether the live layout could be read at all. Surfaced for diagnostics rather than
    /// leaving "we are guessing" invisible.
    static func isResolvedFromLiveLayout(_ character: Character) -> Bool {
        table()[character] != nil
    }

    /// Called when the selected input source changes, since the mapping changes with it.
    static func invalidate() {
        cache.value = nil
    }

    /// Watch for the user switching input source. Carbon posts this as a *distributed*
    /// notification, not through `NotificationCenter`, which is why it is easy to miss.
    static func startObserving() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in invalidate() }
    }

    /// What a key code types on the live layout. Used by the self-check to prove the mapping
    /// round-trips rather than merely being non-empty.
    static func character(for keyCode: UInt16) -> Character? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        guard let produced = translate(data: data, keyCode: keyCode, kbdType: UInt32(LMGetKbdType())),
              let character = produced.lowercased().first
        else { return nil }
        return character
    }

    private static func table() -> [Character: UInt16] {
        if let cached = cache.value { return cached }
        let built = build() ?? [:]
        cache.value = built
        return built
    }

    /// Walk the key codes and record what each one types, lowest first.
    ///
    /// Ascending order matters: the numeric keypad also types `-` and `=`, at higher codes than
    /// the main row, and a keypad key is not what an app's ⌘- menu item is listening for.
    private static func build() -> [Character: UInt16]? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let kbdType = UInt32(LMGetKbdType())

        var table: [Character: UInt16] = [:]
        for keyCode in UInt16(0)..<128 {
            guard let produced = translate(data: data, keyCode: keyCode, kbdType: kbdType),
                  produced.count == 1,
                  let character = produced.lowercased().first,
                  table[character] == nil
            else { continue }
            table[character] = keyCode
        }
        return table.isEmpty ? nil : table
    }

    private static func translate(data: Data, keyCode: UInt16, kbdType: UInt32) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                0, // no modifiers: the unshifted character is the one shortcuts are written in
                kbdType,
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
