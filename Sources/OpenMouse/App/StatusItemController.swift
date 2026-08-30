import AppKit

/// Menu bar entry point. The menu is rebuilt on open so the check marks always reflect the
/// live preferences, even when they were changed from the settings window.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let onOpenSettings: () -> Void
    private var store: SettingsStore { SettingsStore.shared }

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = item.button else { return }
        let enabled = store.preferences.enabled && MouseEngine.shared.status.isRunning
        let name = enabled ? "computermouse.fill" : "computermouse"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: Strings.appName)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !enabled
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = store.preferences

        menu.addItem(statusHeader())
        menu.addItem(.separator())

        menu.addItem(toggle(
            title: Strings.menuEnabled,
            isOn: prefs.enabled,
            action: #selector(toggleEnabled)
        ))
        menu.addItem(toggle(
            title: Strings.menuSmoothing,
            isOn: prefs.scroll.smoothingEnabled,
            action: #selector(toggleSmoothing),
            enabled: prefs.enabled
        ))
        menu.addItem(toggle(
            title: Strings.menuReverse,
            isOn: prefs.scroll.reverseVertical,
            action: #selector(toggleReverse),
            enabled: prefs.enabled
        ))

        menu.addItem(.separator())

        if let bundleID = store.frontmostBundleID {
            let isExcluded = prefs.rules.contains { $0.bundleID == bundleID && $0.mode == .bypass }
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? bundleID
            let entry = NSMenuItem(
                title: isExcluded
                    ? Strings.menuIncludeApp(name)
                    : Strings.menuExcludeApp(name),
                action: #selector(toggleFrontmostApp),
                keyEquivalent: ""
            )
            entry.target = self
            menu.addItem(entry)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: Strings.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: Strings.menuQuit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func statusHeader() -> NSMenuItem {
        let text: String
        switch MouseEngine.shared.status {
        case .running: text = Strings.statusRunning
        case .needsPermission: text = Strings.statusNeedsPermission
        case .failed: text = Strings.statusFailed
        case .off: text = Strings.statusOff
        }
        let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func toggle(
        title: String,
        isOn: Bool,
        action: Selector,
        enabled: Bool = true
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.state = isOn ? .on : .off
        entry.isEnabled = enabled
        return entry
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        store.preferences.enabled.toggle()
        refreshIcon()
    }

    @objc private func toggleSmoothing() {
        store.preferences.scroll.smoothingEnabled.toggle()
    }

    @objc private func toggleReverse() {
        store.preferences.scroll.reverseVertical.toggle()
    }

    @objc private func toggleFrontmostApp() {
        guard let bundleID = store.frontmostBundleID else { return }
        if let index = store.preferences.rules.firstIndex(where: { $0.bundleID == bundleID && $0.mode == .bypass }) {
            store.preferences.rules.remove(at: index)
        } else {
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? bundleID
            store.addRule(bundleID: bundleID, name: name)
        }
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
