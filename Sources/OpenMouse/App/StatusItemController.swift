import AppKit
import Observation

/// The menu-bar icon is a projection of two independently observable values. Keeping the
/// projection pure lets self-checks pin the exact disabled/running presentation without
/// constructing an `NSStatusItem`.
struct StatusItemPresentation: Equatable {
    let symbolName: String
    let appearsDisabled: Bool

    init(symbolName: String, appearsDisabled: Bool) {
        self.symbolName = symbolName
        self.appearsDisabled = appearsDisabled
    }

    init(preferencesEnabled: Bool, engineRunning: Bool) {
        let active = preferencesEnabled && engineRunning
        symbolName = active ? "computermouse.fill" : "computermouse"
        appearsDisabled = !active
    }
}

private enum StatusMenuLayout {
    // All non-separator rows share one compact layout. The right indicator column
    // is used by both checkmarks and keyboard shortcuts.
    static let titleInset: CGFloat = 12
    static let indicatorGap: CGFloat = 12
    static let trailingInset: CGFloat = 12
    static let rowHeight: CGFloat = 24
}

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
        menu.autoenablesItems = false
        // Rows draw the checkmark column themselves so it can live beside the
        // shortcut column instead of being forced to the far left.
        menu.showsStateColumn = false
        menu.minimumWidth = 0
        item.menu = menu
        observeIconState()
    }

    private func observeIconState() {
        let presentation = withObservationTracking {
            StatusItemPresentation(
                preferencesEnabled: store.preferences.enabled,
                engineRunning: MouseEngine.shared.status.isRunning
            )
        } onChange: {
            Task { @MainActor [weak self] in
                self?.observeIconState()
            }
        }
        refreshIcon(using: presentation)
    }

    private func refreshIcon(using presentation: StatusItemPresentation) {
        guard let button = item.button else { return }
        let image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: Strings.appName
        )
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = presentation.appearsDisabled
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Opening the menu is a good moment to re-check: a warning about an app the user
        // already quit is worse than no warning.
        ConflictMonitor.shared.refreshNow()
        // Cheap, and the only moment the user is looking: pick up shortcuts they may have just
        // changed in System Settings without making them relaunch.
        SystemHotkeys.invalidate()
        KeyboardLayout.invalidate()
        menu.removeAllItems()
        let prefs = store.preferences
        let frontmostAppName = store.frontmostBundleID.map {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? $0
        }
        let shortcutContentWidth = menuContentWidth(frontmostAppName: frontmostAppName)

        menu.addItem(statusHeader(contentWidth: shortcutContentWidth))
        menu.addItem(.separator())

        menu.addItem(toggle(
            title: Strings.menuEnabled,
            isOn: prefs.enabled,
            action: #selector(toggleEnabled),
            contentWidth: shortcutContentWidth
        ))
        menu.addItem(toggle(
            title: Strings.menuSmoothing,
            isOn: prefs.scroll.smoothingEnabled,
            action: #selector(toggleSmoothing),
            enabled: prefs.enabled,
            contentWidth: shortcutContentWidth
        ))
        menu.addItem(toggle(
            title: Strings.menuReverse,
            isOn: prefs.scroll.reverseVertical,
            action: #selector(toggleReverse),
            enabled: prefs.enabled,
            contentWidth: shortcutContentWidth
        ))

        menu.addItem(.separator())

        if let bundleID = store.frontmostBundleID {
            let isExcluded = prefs.rules.contains { $0.bundleID == bundleID && $0.mode == .bypass }
            let name = frontmostAppName ?? bundleID
            let entry = NSMenuItem(
                title: isExcluded
                    ? Strings.menuIncludeApp(name)
                    : Strings.menuExcludeApp(name),
                action: #selector(toggleFrontmostApp),
                keyEquivalent: ""
            )
            entry.target = self
            entry.view = StatusMenuRowView(
                title: entry.title,
                showsCheckmark: false,
                shortcut: nil,
                contentWidth: shortcutContentWidth
            )
            menu.addItem(entry)
            menu.addItem(.separator())
        }

        let settings = shortcutItem(
            title: Strings.menuSettings,
            shortcut: "⌘,",
            action: #selector(openSettings),
            contentWidth: shortcutContentWidth
        )
        menu.addItem(settings)

        let quit = shortcutItem(
            title: Strings.menuQuit,
            shortcut: "⌘Q",
            action: #selector(quit),
            contentWidth: shortcutContentWidth
        )
        menu.addItem(quit)
    }

    /// A custom view controls the entire row, including its shortcut label, so
    /// AppKit cannot insert an automatic Settings icon. Keep real key equivalents
    /// on the items so keyboard activation still works.
    private func shortcutItem(
        title: String,
        shortcut: String,
        action: Selector,
        contentWidth: CGFloat
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: shortcut == "⌘," ? "," : "q")
        entry.target = self
        entry.view = StatusMenuRowView(
            title: title,
            showsCheckmark: false,
            shortcut: shortcut,
            contentWidth: contentWidth
        )
        return entry
    }

    private func menuContentWidth(frontmostAppName: String?) -> CGFloat {
        let titles = [
            statusText,
            Strings.menuEnabled,
            Strings.menuSmoothing,
            Strings.menuReverse,
            Strings.menuSettings,
            Strings.menuQuit
        ] + (frontmostAppName.map { [Strings.menuExcludeApp($0), Strings.menuIncludeApp($0)] } ?? [])
        let font = NSFont.menuFont(ofSize: 0)
        let titleWidth = titles.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let shortcutWidth = ["⌘,", "⌘Q"].map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let checkmarkFont = NSFont.systemFont(ofSize: 16, weight: .medium)
        let checkmarkWidth = ("✓" as NSString).size(withAttributes: [.font: checkmarkFont]).width
        let indicatorWidth = max(shortcutWidth, checkmarkWidth)
        return ceil(
            StatusMenuLayout.titleInset
                + titleWidth
                + StatusMenuLayout.indicatorGap
                + indicatorWidth
                + StatusMenuLayout.trailingInset
        )
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for entry in menu.items {
            (entry.view as? StatusMenuRowView)?.highlighted = entry === item
        }
    }

    private var statusText: String {
        let text: String
        switch MouseEngine.shared.status {
        case .running: text = Strings.statusRunning
        case .needsPermission: text = Strings.statusNeedsPermission
        case .failed: text = Strings.statusFailed
        case .off: text = Strings.statusOff
        }
        return text
    }

    private func statusHeader(contentWidth: CGFloat) -> NSMenuItem {
        let text = statusText
        let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        entry.view = StatusMenuRowView(
            title: text,
            showsCheckmark: false,
            shortcut: nil,
            contentWidth: contentWidth
        )
        return entry
    }

    private func toggle(
        title: String,
        isOn: Bool,
        action: Selector,
        enabled: Bool = true,
        contentWidth: CGFloat
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.state = isOn ? .on : .off
        entry.isEnabled = enabled
        entry.view = StatusMenuRowView(
            title: title,
            showsCheckmark: true,
            shortcut: nil,
            contentWidth: contentWidth
        )
        return entry
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        store.preferences.enabled.toggle()
    }

    @objc private func toggleSmoothing() {
        store.preferences.scroll.smoothingEnabled.toggle()
    }

    @objc private func toggleReverse() {
        store.preferences.scroll.reverseVertical.toggle()
    }

    @objc private func toggleFrontmostApp() {
        guard let bundleID = store.frontmostBundleID else { return }
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? bundleID
        store.toggleBypassRule(bundleID: bundleID, name: name)
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Draws one menu row with a shared title column and a shared trailing indicator
/// column. The indicator is either a native-looking checkmark or a shortcut label.
private final class StatusMenuRowView: NSView {
    private let titleText: String
    private let showsCheckmark: Bool
    private let shortcutText: String?
    private let textFont = NSFont.menuFont(ofSize: 0)
    var highlighted = false {
        didSet { needsDisplay = true }
    }

    init(title: String, showsCheckmark: Bool, shortcut: String?, contentWidth: CGFloat) {
        titleText = title
        self.showsCheckmark = showsCheckmark
        shortcutText = shortcut
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: StatusMenuLayout.rowHeight
        ))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // NSMenuItem custom views must dispatch their own mouse activation.
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    private func activate() {
        guard let item = enclosingMenuItem, item.isEnabled,
              let action = item.action, let menu = item.menu else { return }
        menu.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }

    override func accessibilityPerformPress() -> Bool {
        guard enclosingMenuItem?.isEnabled == true else { return false }
        activate()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(titleText)
        setAccessibilityEnabled(enclosingMenuItem?.isEnabled ?? false)
        if showsCheckmark {
            setAccessibilityValue(enclosingMenuItem?.state == .on ? 1 : 0)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let item = enclosingMenuItem
        let highlighted = (highlighted || item?.isHighlighted == true) && item?.isEnabled == true
        let enabled = item?.isEnabled ?? true
        let color: NSColor
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 4, dy: 1),
                xRadius: 5,
                yRadius: 5
            ).fill()
            color = .selectedMenuItemTextColor
        } else if enabled {
            color = .labelColor
        } else {
            color = .tertiaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: color
        ]
        let titleSize = (titleText as NSString).size(withAttributes: attributes)
        (titleText as NSString).draw(
            at: NSPoint(
                x: StatusMenuLayout.titleInset,
                y: (bounds.height - titleSize.height) / 2
            ),
            withAttributes: attributes
        )

        if showsCheckmark, item?.state == .on {
            let checkmarkAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: color
            ]
            let checkmark = "✓" as NSString
            let checkmarkSize = checkmark.size(withAttributes: checkmarkAttributes)
            checkmark.draw(
                at: NSPoint(
                    x: bounds.width - StatusMenuLayout.trailingInset - checkmarkSize.width,
                    y: (bounds.height - checkmarkSize.height) / 2
                ),
                withAttributes: checkmarkAttributes
            )
        } else if let shortcutText {
            let shortcutSize = (shortcutText as NSString).size(withAttributes: attributes)
            shortcutText.draw(
                at: NSPoint(
                    x: bounds.width - StatusMenuLayout.trailingInset - shortcutSize.width,
                    y: (bounds.height - shortcutSize.height) / 2
                ),
                withAttributes: attributes
            )
        }
    }
}
