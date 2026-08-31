import CoreGraphics
import Foundation
import os

/// Structured tracing for the parts of the pipeline that have no visible output.
///
/// The scroll path can be judged by feel, but a button binding either fires or silently does
/// not, and a menu-bar app has no console to say which. These go to the unified log at
/// `notice` level so they survive a normal `open`-launched run and can be read back with:
///
///     log show --last 2m --predicate 'subsystem == "com.openmouse.OpenMouse"'
///
/// Deliberately not on the scroll path: that runs per frame and would flood the log.
enum Trace {
    private static let tap = Logger(subsystem: "com.openmouse.OpenMouse", category: "tap")
    private static let gesture = Logger(subsystem: "com.openmouse.OpenMouse", category: "gesture")

    /// Motion fires per pixel of travel. A few samples per hold is enough to tell a real
    /// swipe from a jiggle; the end-of-hold summary carries the totals.
    private static let motionLogLimit = 4

    static func tapStarted(kind: String, mask: CGEventMask, ok: Bool) {
        tap.notice("tap \(kind, privacy: .public) start ok=\(ok) mask=0x\(String(mask, radix: 16), privacy: .public)")
    }

    static func tapStopped(kind: String) {
        tap.notice("tap \(kind, privacy: .public) stop")
    }

    static func tapAutoReenabled(kind: String, reason: String) {
        tap.notice("tap \(kind, privacy: .public) auto-reenabled reason=\(reason, privacy: .public)")
    }

    static func buttonSeen(button: Int, isDown: Bool, action: String) {
        gesture.notice("button \(button) \(isDown ? "down" : "up", privacy: .public) → \(action, privacy: .public)")
    }

    static func buttonUnbound(button: Int) {
        gesture.notice("button \(button) has no binding, passed through")
    }

    static func gestureBegan(button: Int) {
        gesture.notice("gesture session began on button \(button)")
    }

    static func gestureEnded(button: Int, asClick: Bool, travelled: Double, motionEvents: Int) {
        gesture.notice("gesture session ended on button \(button) asClick=\(asClick) travelled=\(travelled, format: .fixed(precision: 1)) motionEvents=\(motionEvents)")
    }

    static func motion(index: Int, type: UInt32, dx: Double, dy: Double, location: CGPoint) {
        guard index < motionLogLimit else { return }
        gesture.notice("""
            motion #\(index) type=\(type) \
            field=(\(dx, format: .fixed(precision: 1)), \(dy, format: .fixed(precision: 1))) \
            at=(\(location.x, format: .fixed(precision: 1)), \(location.y, format: .fixed(precision: 1)))
            """)
    }

    /// An action that resolved to nothing. Without this the failure mode is an app that
    /// cheerfully does nothing, which is the hardest kind of bug to report.
    static func actionUnavailable(action: String, reason: String) {
        gesture.notice("action \(action, privacy: .public) unavailable: \(reason, privacy: .public)")
    }

    static func conflicts(_ names: [String], trigger: String) {
        tap.notice("conflicts=[\(names.joined(separator: ", "), privacy: .public)] via \(trigger, privacy: .public)")
    }

    static func recognized(direction: String, action: String) {
        gesture.notice("recognized \(direction, privacy: .public) → \(action, privacy: .public)")
    }
}
