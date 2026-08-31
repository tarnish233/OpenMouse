import CoreGraphics

/// One mandatory marker for every event Open Mouse synthesises.
///
/// Event taps must pass marked events through immediately. Keeping the magic value and the
/// write/check operations here makes it difficult for a new posting path to invent a second
/// convention or forget the marker entirely.
enum SyntheticEventTag {
    /// Arbitrary but distinctive; "OMSE" as an integer-ish marker.
    static let magic: Int64 = 0x4F4D_5345

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: magic)
    }

    static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == magic
    }
}
