import AppKit
import SwiftUI

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case scroll
    case pointer
    case buttons
    case apps
    case general

    var id: Self { self }

    var title: String {
        switch self {
        case .scroll: Strings.tabScroll
        case .pointer: Strings.tabPointer
        case .buttons: Strings.tabButtons
        case .apps: Strings.tabApps
        case .general: Strings.tabGeneral
        }
    }

    var systemImage: String {
        switch self {
        case .scroll: "arrow.up.arrow.down"
        case .pointer: "cursorarrow.motionlines"
        case .buttons: "computermouse"
        case .apps: "square.grid.2x2"
        case .general: "gearshape"
        }
    }
}

/// Commits navigation and history only after the user has resolved the current draft.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation(confirmLeave: { completion in
        SettingsLeaveConfirmation.request(completion: completion)
    })

    // List highlights a row optimistically. Keep that tentative selection separate from
    // the committed pane so Cancel can explicitly restore both the row and its content.
    var sidebarSelection: SettingsTab? {
        didSet {
            guard let tab = sidebarSelection else {
                sidebarSelection = selectedTab
                return
            }
            if tab != selectedTab { select(tab) }
        }
    }
    private(set) var history: [SettingsTab]
    private(set) var historyIndex = 0
    private(set) var isNavigationPending = false
    var selectedTab: SettingsTab { history[historyIndex] }
    var canGoBack: Bool { historyIndex > 0 && !isNavigationPending }
    var canGoForward: Bool { historyIndex < history.count - 1 && !isNavigationPending }
    @ObservationIgnored private let confirmLeave: (@escaping (Bool) -> Void) -> Bool

    init(
        initialTab: SettingsTab = .scroll,
        confirmLeave: @escaping (@escaping (Bool) -> Void) -> Bool
    ) {
        history = [initialTab]
        sidebarSelection = initialTab
        self.confirmLeave = confirmLeave
    }

    func select(_ tab: SettingsTab?) {
        guard let tab, tab != selectedTab else { return }
        navigate(to: tab, historyIndex: nil)
    }

    func goBack() {
        guard canGoBack else { return }
        navigate(to: history[historyIndex - 1], historyIndex: historyIndex - 1)
    }

    func goForward() {
        guard canGoForward else { return }
        navigate(to: history[historyIndex + 1], historyIndex: historyIndex + 1)
    }

    private func navigate(to tab: SettingsTab, historyIndex targetIndex: Int?) {
        guard !isNavigationPending else {
            sidebarSelection = selectedTab
            return
        }
        isNavigationPending = true
        let accepted = confirmLeave { [weak self] shouldLeave in
            guard let self else { return }
            if shouldLeave {
                if let targetIndex {
                    self.historyIndex = targetIndex
                } else {
                    self.history = Array(self.history.prefix(self.historyIndex + 1)) + [tab]
                    self.historyIndex = self.history.count - 1
                }
            }
            self.sidebarSelection = self.selectedTab
            self.isNavigationPending = false
        }
        if !accepted {
            sidebarSelection = selectedTab
            isNavigationPending = false
        }
    }
}

enum AppVersion {
    static let unknown = "未知"

    static func value(_ key: String, in info: [String: Any]?) -> String {
        guard let value = info?[key] as? String, !value.isEmpty else { return unknown }
        return value
    }

    static let short = value("CFBundleShortVersionString", in: Bundle.main.infoDictionary)
    static let build = value("CFBundleVersion", in: Bundle.main.infoDictionary)
    static let displayString: String = "\(short) (\(build))"
}

// MARK: - Root

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var store = SettingsStore.shared

    private var activeTab: SettingsTab { navigation.selectedTab }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(selectedTab: $navigation.sidebarSelection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetail(tab: activeTab)
        }
        .navigationTitle(Strings.settingsTitle)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 520)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { navigation.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!navigation.canGoBack)
                Button { navigation.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!navigation.canGoForward)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(Strings.settingsRevert) { store.discardEdits() }
                    .disabled(!store.hasUnsavedChanges)
                    .help(Strings.settingsRevertHelp)
                SaveButton(hasUnsavedChanges: store.hasUnsavedChanges) {
                    store.saveEdits()
                }
            }
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selectedTab: SettingsTab?
    @State private var engine = MouseEngine.shared

    var body: some View {
        List(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    Image(systemName: tab.systemImage)
                }
                .foregroundStyle(.primary)
                .tag(tab)
            }

            EngineStatusFooter(status: engine.status)
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyleSoftIfAvailable()
        .navigationTitle(Strings.settingsTitle)
    }
}

private struct EngineStatusFooter: View {
    let status: MouseEngine.Status

    private var color: Color {
        switch status {
        case .running: .green
        case .needsPermission, .failed: .orange
        case .off: .secondary
        }
    }

    private var label: String {
        switch status {
        case .running: Strings.statusRunning
        case .needsPermission: Strings.statusNeedsPermission
        case .failed: Strings.statusFailed
        case .off: Strings.statusOff
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0.height }
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(AppVersion.displayString)
                .font(.footnote)
                .fontDesign(.monospaced)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .selectionDisabled()
    }
}

// MARK: - Save

/// Keep the pending-save state visible even before the user tries to leave the page.
private struct SaveButton: View {
    let hasUnsavedChanges: Bool
    let action: () -> Void

    var body: some View {
        if hasUnsavedChanges {
            Button(Strings.settingsSave, action: action)
                .buttonStyle(.borderedProminent)
                .help(Strings.settingsSaveHelp)
                .keyboardShortcut("s", modifiers: .command)
        } else {
            Label(Strings.settingsSaved, systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .help(Strings.settingsSavedHelp)
        }
    }
}

// MARK: - Detail

private struct SettingsDetail: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .scroll: ScrollSettingsPane()
            case .pointer: PointerSettingsPane()
            case .buttons: ButtonsSettingsPane()
            case .apps: AppRulesPane()
            case .general: GeneralSettingsPane()
            }
        }
        .navigationTitle(tab.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Availability helpers

extension View {
    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
