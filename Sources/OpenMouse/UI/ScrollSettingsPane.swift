import SwiftUI

struct ScrollSettingsPane: View {
    @State private var store = SettingsStore.shared

    private var scroll: Binding<ScrollSettings> {
        $store.preferences.scroll
    }

    var body: some View {
        Form {
            PermissionBanner()

            Section(Strings.scrollSectionBasics) {
                Toggle(isOn: scroll.smoothingEnabled) {
                    LabelWithHelp(Strings.scrollEnableSmoothing, help: Strings.scrollEnableSmoothingHelp)
                }
                .toggleStyle(.switch)

                Toggle(Strings.scrollReverseVertical, isOn: scroll.reverseVertical)
                    .toggleStyle(.switch)
                Toggle(Strings.scrollReverseHorizontal, isOn: scroll.reverseHorizontal)
                    .toggleStyle(.switch)
            }

            Section(Strings.scrollSectionFeel) {
                LabeledContent(Strings.scrollPresets) {
                    HStack(spacing: 8) {
                        presetButton(Strings.presetDefault, value: .default)
                        presetButton(Strings.presetSmooth, value: .smooth)
                        presetButton(Strings.presetCrisp, value: .crisp)
                    }
                }

                SliderRow(
                    title: Strings.scrollMinimumStep,
                    help: Strings.scrollMinimumStepHelp,
                    value: scroll.minimumStep,
                    range: 4...120,
                    step: 0.2,
                    format: { String(format: "%.1f px", $0) }
                )

                SliderRow(
                    title: Strings.scrollSpeed,
                    help: Strings.scrollSpeedHelp,
                    value: scroll.speed,
                    range: 0.5...8,
                    step: 0.05,
                    format: { String(format: "%.2f×", $0) }
                )

                SliderRow(
                    title: Strings.scrollSmoothness,
                    help: Strings.scrollSmoothnessHelp,
                    value: scroll.smoothness,
                    range: 0...ScrollSettings.maxSmoothness,
                    step: 0.005,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                .disabled(!store.preferences.scroll.smoothingEnabled)

                SliderRow(
                    title: Strings.scrollAcceleration,
                    help: Strings.scrollAccelerationHelp,
                    value: scroll.acceleration,
                    range: 1...6,
                    step: 0.1,
                    format: { String(format: "%.1f×", $0) }
                )
                .disabled(!store.preferences.scroll.smoothingEnabled)
            }

            Section {
                ScrollFeelPreview()
            } header: {
                Text("试一试")
            } footer: {
                Text("在上面的区域滚动，可以立刻感受当前参数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(Strings.scrollReverseTrackpad, isOn: scroll.reverseContinuousDevices)
                    .toggleStyle(.switch)
                Toggle(Strings.scrollSmoothTrackpad, isOn: scroll.affectContinuousDevices)
                    .toggleStyle(.switch)
            } header: {
                Text(Strings.scrollSectionTrackpad)
            } footer: {
                Text(Strings.scrollTrackpadNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(Strings.scrollSectionAdvanced) {
                Toggle(isOn: scroll.emitScrollPhases) {
                    LabelWithHelp(Strings.scrollEmitPhases, help: Strings.scrollEmitPhasesHelp)
                }
                .toggleStyle(.switch)

                HStack {
                    Spacer()
                    Button(Strings.resetScroll) { store.resetScroll() }
                        .controlSize(.small)
                        .disabled(store.preferences.scroll == .default)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private func presetButton(_ title: String, value: ScrollSettings) -> some View {
        Button(title) {
            var next = value
            // Presets tune the feel only; direction and device choices are the user's.
            next.reverseVertical = store.preferences.scroll.reverseVertical
            next.reverseHorizontal = store.preferences.scroll.reverseHorizontal
            next.reverseContinuousDevices = store.preferences.scroll.reverseContinuousDevices
            next.affectContinuousDevices = store.preferences.scroll.affectContinuousDevices
            next.emitScrollPhases = store.preferences.scroll.emitScrollPhases
            next.smoothingEnabled = store.preferences.scroll.smoothingEnabled
            store.preferences.scroll = next
        }
        .controlSize(.small)
    }
}

// MARK: - Building blocks

private struct LabelWithHelp: View {
    let title: String
    let help: String

    init(_ title: String, help: String) {
        self.title = title
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SliderRow: View {
    let title: String
    let help: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 200)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        } label: {
            if let help {
                LabelWithHelp(title, help: help)
            } else {
                Text(title)
            }
        }
    }
}

/// A short scrollable strip so tuning the sliders has immediate, physical feedback.
private struct ScrollFeelPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(1...40, id: \.self) { index in
                    HStack {
                        Text(String(format: "%02d", index))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Rectangle()
                            .fill(.tint.opacity(index % 5 == 0 ? 0.35 : 0.12))
                            .frame(height: 6)
                            .clipShape(.capsule)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(height: 132)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}
