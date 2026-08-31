import AppKit
import SwiftUI

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case scroll
    case buttons
    case apps
    case general

    var id: Self { self }

    var title: String {
        switch self {
        case .scroll: Strings.tabScroll
        case .buttons: Strings.tabButtons
        case .apps: Strings.tabApps
        case .general: Strings.tabGeneral
        }
    }

    var systemImage: String {
        switch self {
        case .scroll: "arrow.up.arrow.down"
        case .buttons: "computermouse"
        case .apps: "square.grid.2x2"
        case .general: "gearshape"
        }
    }
}

/// Singleton so the menu bar can deep-link into a specific pane.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .scroll
    private init() {}
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
    @State private var history: [SettingsTab] = [.scroll]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

    private var activeTab: SettingsTab { navigation.selectedTab ?? .scroll }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(selectedTab: $navigation.selectedTab)
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
                Button { goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(historyIndex <= 0)
                Button { goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(historyIndex >= history.count - 1)
            }
        }
        .onChange(of: navigation.selectedTab) { _, _ in record() }
    }

    private func goBack() {
        guard historyIndex > 0 else { return }
        isHistoryNavigation = true
        historyIndex -= 1
        navigation.selectedTab = history[historyIndex]
        Task { @MainActor in isHistoryNavigation = false }
    }

    private func goForward() {
        guard historyIndex < history.count - 1 else { return }
        isHistoryNavigation = true
        historyIndex += 1
        navigation.selectedTab = history[historyIndex]
        Task { @MainActor in isHistoryNavigation = false }
    }

    private func record() {
        guard !isHistoryNavigation, let tab = navigation.selectedTab, history.last != tab else { return }
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(tab)
        historyIndex = history.count - 1
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

// MARK: - Detail

private struct SettingsDetail: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .scroll: ScrollSettingsPane()
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
