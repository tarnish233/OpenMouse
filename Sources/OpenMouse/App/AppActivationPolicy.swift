import AppKit

/// A menu-bar-only app has no Dock icon, so its windows cannot become key until the
/// activation policy is temporarily promoted. Reference counted because more than one
/// window may want the app in the foreground.
@MainActor
enum AppActivationPolicy {
    private static var count = 0

    static func enter() {
        count += 1
        refreshDockIcon()
        // Promotion and foreground activation are separate operations. The window controller
        // waits for `didBecomeActive` before ordering its window, so it can never flash above the
        // current app via `orderFrontRegardless` and then fall behind it.
        NSApp.setActivationPolicy(.regular)
    }

    /// Launch Services can retain an older icon for an LSUIElement bundle even after the app
    /// itself has been replaced. Setting the bundled image explicitly before promotion makes the
    /// temporary Dock icon follow the currently running build instead of that stale cache entry.
    private static func refreshDockIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        icon.isTemplate = false
        NSApp.applicationIconImage = icon
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

/// One visible window owns one activation-policy reference. Repeated attempts to show the
/// same window are idempotent, while distinct windows can still hold independent leases.
@MainActor
final class AppActivationLease {
    private let onEnter: () -> Void
    private let onLeave: () -> Void
    private(set) var isHeld = false

    init(onEnter: @escaping () -> Void, onLeave: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onLeave = onLeave
    }

    func enter() {
        guard !isHeld else { return }
        isHeld = true
        onEnter()
    }

    func leave() {
        guard isHeld else { return }
        isHeld = false
        onLeave()
    }
}
