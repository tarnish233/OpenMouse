import AppKit
import ApplicationServices

/// Accessibility ("控制您的电脑") is required because the event tap modifies and swallows
/// events. Input Monitoring alone is only enough for a listen-only tap.
enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt once per app launch; subsequent calls are silent if the
    /// user already dismissed it.
    static func requestPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
