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
