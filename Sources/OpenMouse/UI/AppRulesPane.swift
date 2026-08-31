import AppKit
import SwiftUI

/// Every stored scroll field must have a control in the per-app custom editor. The editor
/// iterates this list and switches exhaustively, while self-checks compare the raw values to
/// `ScrollSettings`' encoded keys so a future model field cannot silently become global-only.
enum AppRuleScrollField: String, CaseIterable, Identifiable {
    case smoothingEnabled
    case reverseVertical
    case reverseHorizontal
    case minimumStep
    case speed
    case smoothness
    case acceleration
    case reverseContinuousDevices
    case affectContinuousDevices
    case emitScrollPhases

    var id: Self { self }
}

struct AppRulesPane: View {
    @State private var store = SettingsStore.shared

    var body: some View {
        Form {
            PermissionBanner()

            Section {
                HStack {
                    Text(Strings.appsIntro)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button(Strings.appsAdd) { addApp() }
                        .controlSize(.small)
                }
            }

            if store.preferences.rules.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(Strings.appsEmpty, systemImage: "square.grid.2x2")
                    } description: {
                        Text("也可以直接从菜单栏为当前最前面的应用一键停用。")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }

            ForEach($store.preferences.rules) { $rule in
                AppRuleSection(rule: $rule) {
                    store.removeRules(ids: [rule.id])
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            store.addRule(bundleID: id, name: name)
        }
    }
}

// MARK: - One rule

private struct AppRuleSection: View {
    @Binding var rule: AppRule
    let onRemove: () -> Void

    var body: some View {
        Section {
            Picker("行为", selection: $rule.mode) {
                Text(Strings.appsModeBypass).tag(AppRule.Mode.bypass)
                Text(Strings.appsModeCustom).tag(AppRule.Mode.custom)
            }
            .pickerStyle(.radioGroup)

            if rule.mode == .custom {
                Toggle(Strings.appsBypassButtons, isOn: $rule.bypassButtons)
                    .toggleStyle(.switch)
                AppRuleScrollControls(scroll: $rule.scroll)
            }
        } header: {
            HStack(spacing: 8) {
                AppIcon(bundleID: rule.bundleID)
                VStack(alignment: .leading, spacing: 0) {
                    Text(rule.name)
                    Text(rule.bundleID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
            .textCase(nil)
        }
    }
}

private struct AppRuleScrollControls: View {
    @Binding var scroll: ScrollSettings

    var body: some View {
        ForEach(AppRuleScrollField.allCases) { field in
            control(for: field)
        }
    }

    @ViewBuilder
    private func control(for field: AppRuleScrollField) -> some View {
        switch field {
        case .smoothingEnabled:
            Toggle(Strings.scrollEnableSmoothing, isOn: $scroll.smoothingEnabled)
                .toggleStyle(.switch)
        case .reverseVertical:
            Toggle(Strings.scrollReverseVertical, isOn: $scroll.reverseVertical)
                .toggleStyle(.switch)
        case .reverseHorizontal:
            Toggle(Strings.scrollReverseHorizontal, isOn: $scroll.reverseHorizontal)
                .toggleStyle(.switch)
        case .minimumStep:
            CompactSlider(
                title: Strings.scrollMinimumStep,
                value: $scroll.minimumStep,
                range: 4...120,
                step: 0.2,
                format: { String(format: "%.1f px", $0) }
            )
        case .speed:
            CompactSlider(
                title: Strings.scrollSpeed,
                value: $scroll.speed,
                range: 0.5...8,
                step: 0.05,
                format: { String(format: "%.2f×", $0) }
            )
        case .smoothness:
            CompactSlider(
                title: Strings.scrollSmoothness,
                value: $scroll.smoothness,
                range: 0...ScrollSettings.maxSmoothness,
                step: 0.005,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            .disabled(!scroll.smoothingEnabled)
        case .acceleration:
            CompactSlider(
                title: Strings.scrollAcceleration,
                value: $scroll.acceleration,
                range: 1...6,
                step: 0.1,
                format: { String(format: "%.1f×", $0) }
            )
            .disabled(!scroll.smoothingEnabled)
        case .reverseContinuousDevices:
            Toggle(Strings.scrollReverseTrackpad, isOn: $scroll.reverseContinuousDevices)
                .toggleStyle(.switch)
        case .affectContinuousDevices:
            Toggle(Strings.scrollSmoothTrackpad, isOn: $scroll.affectContinuousDevices)
                .toggleStyle(.switch)
        case .emitScrollPhases:
            Toggle(Strings.scrollEmitPhases, isOn: $scroll.emitScrollPhases)
                .toggleStyle(.switch)
        }
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: 18, height: 18)
    }

    private var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

private struct CompactSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 180)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}
