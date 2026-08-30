import AppKit

/// A menu-bar-only app has no Dock icon, so its windows cannot become key until the
/// activation policy is temporarily promoted. Reference counted because more than one
/// window may want the app in the foreground.
@MainActor
enum AppActivationPolicy {
    private static var count = 0

    static func enter() {
        count += 1
        // `activate(ignoringOtherApps:)` is deprecated on recent macOS and can be ignored
        // outright under cooperative activation; `activate()` is the supported form.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func leave() {
        count = max(0, count - 1)
        guard count == 0 else { return }
        Task { @MainActor in
            guard count == 0 else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
