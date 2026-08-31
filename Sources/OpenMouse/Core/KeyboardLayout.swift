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
    /// Every `.character` action must have an entry here. This is intentionally checked from
    /// `ActionRunner.stroke(for:)`, rather than by comparing this table with a hand-maintained
    /// duplicate list. If a future action forgets its fallback, resolution returns `nil` and the
    /// action is skipped with a diagnostic instead of silently posting some unrelated real key.
    static let ansiFallback: [Character: UInt16] = [
        "a": UInt16(kVK_ANSI_A), "c": UInt16(kVK_ANSI_C), "d": UInt16(kVK_ANSI_D),
        "f": UInt16(kVK_ANSI_F), "g": UInt16(kVK_ANSI_G), "h": UInt16(kVK_ANSI_H),
        "i": UInt16(kVK_ANSI_I), "m": UInt16(kVK_ANSI_M), "n": UInt16(kVK_ANSI_N),
        "q": UInt16(kVK_ANSI_Q), "t": UInt16(kVK_ANSI_T), "v": UInt16(kVK_ANSI_V),
        "w": UInt16(kVK_ANSI_W), "x": UInt16(kVK_ANSI_X), "z": UInt16(kVK_ANSI_Z),
        "1": UInt16(kVK_ANSI_1), "2": UInt16(kVK_ANSI_2), "3": UInt16(kVK_ANSI_3),
        "4": UInt16(kVK_ANSI_4), "8": UInt16(kVK_ANSI_8),
        "[": UInt16(kVK_ANSI_LeftBracket), "]": UInt16(kVK_ANSI_RightBracket),
        "-": UInt16(kVK_ANSI_Minus), "=": UInt16(kVK_ANSI_Equal)
    ]

    private static let cache = Locked<[Character: UInt16]?>(nil)

    /// The key code that types `character` right now, or the ANSI position if known.
    static func keyCode(for character: Character) -> UInt16? {
        table()[character] ?? ansiFallback[character]
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
        resolveTable(cache: cache, builder: build)
    }

    /// Resolve through a supplied cache/build pair so the failure path can be asserted without
    /// depending on the machine's current TIS state. A failed build is deliberately not stored:
    /// the next action gets another chance after transient startup/input-source failures.
    static func resolveTable(
        cache: Locked<[Character: UInt16]?>,
        builder: () -> [Character: UInt16]?
    ) -> [Character: UInt16] {
        if let cached = cache.value { return cached }
        guard let built = builder() else { return [:] }
        return cache.withValue { cached in
            if let cached { return cached }
            cached = built
            return built
        }
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
