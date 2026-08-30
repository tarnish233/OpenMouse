import AppKit
import SwiftUI

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
                Toggle(Strings.scrollEnableSmoothing, isOn: $rule.scroll.smoothingEnabled)
                    .toggleStyle(.switch)
                Toggle(Strings.scrollReverseVertical, isOn: $rule.scroll.reverseVertical)
                    .toggleStyle(.switch)
                CompactSlider(
                    title: Strings.scrollMinimumStep,
                    value: $rule.scroll.minimumStep,
                    range: 4...120,
                    step: 0.2,
                    format: { String(format: "%.1f px", $0) }
                )
                CompactSlider(
                    title: Strings.scrollSpeed,
                    value: $rule.scroll.speed,
                    range: 0.5...8,
                    step: 0.05,
                    format: { String(format: "%.2f×", $0) }
                )
                CompactSlider(
                    title: Strings.scrollSmoothness,
                    value: $rule.scroll.smoothness,
                    range: 0...ScrollSettings.maxSmoothness,
                    step: 0.005,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
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
