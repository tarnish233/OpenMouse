import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(
            onOpenSettings: { [weak self] in self?.showSettings() }
        )
        MouseEngine.shared.start()
        ConflictMonitor.shared.start()
        KeyboardLayout.startObserving()
        UpdateCoordinator.shared.startAutomaticChecks()

        if VerboseLogger.isRequested {
            VerboseLogger.shared.start()
        }

        if let tab = Self.requestedTab() {
            SettingsWindowController.show(tab: tab)
        } else if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.requestPrompt()
            showSettings()
        }
    }

    /// `OpenMouse --tab buttons` opens straight to one pane. Handy when reproducing a UI
    /// bug without clicking through the sidebar.
    private static func requestedTab() -> SettingsTab? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--tab"), index + 1 < args.count else { return nil }
        return SettingsTab(rawValue: args[index + 1])
    }

    func applicationWillTerminate(_ notification: Notification) {
        MouseEngine.shared.stop()
        SettingsStore.shared.saveNow()
    }

    /// Clicking the app in Finder while it is already running should reopen settings
    /// rather than appear to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        SettingsWindowController.show()
    }
}
