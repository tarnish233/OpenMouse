import AppKit
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
                Toggle(Strings.scrollEnableSmoothing, isOn: scroll.smoothingEnabled)
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
                    value: scroll.minimumStep,
                    range: 4...120,
                    step: 0.2,
                    format: { String(format: "%.1f px", $0) }
                )

                SliderRow(
                    title: Strings.scrollSpeed,
                    value: scroll.speed,
                    range: 0.5...8,
                    step: 0.05,
                    format: { String(format: "%.2f×", $0) }
                )

                SliderRow(
                    title: Strings.scrollSmoothness,
                    value: scroll.smoothness,
                    range: 0...ScrollSettings.maxSmoothness,
                    step: 0.005,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                .disabled(!store.preferences.scroll.smoothingEnabled)

                SliderRow(
                    title: Strings.scrollAcceleration,
                    value: scroll.acceleration,
                    range: 1...6,
                    step: 0.1,
                    format: { String(format: "%.1f×", $0) }
                )
                .disabled(!store.preferences.scroll.smoothingEnabled)
            }

            Section {
                Button {
                    ScrollComparisonWindowController.show()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(Strings.scrollTryButton)
                                .foregroundStyle(.primary)
                            Text(Strings.scrollTryButtonHelp)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Strings.scrollTryButtonHelp)
            }

            Section(Strings.scrollSectionTrackpad) {
                Toggle(Strings.scrollReverseTrackpad, isOn: scroll.reverseContinuousDevices)
                    .toggleStyle(.switch)
                Toggle(Strings.scrollSmoothTrackpad, isOn: scroll.affectContinuousDevices)
                    .toggleStyle(.switch)
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
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    private var steppedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { proposedValue in
                let clamped = min(max(proposedValue, range.lowerBound), range.upperBound)
                let stepCount = ((clamped - range.lowerBound) / step).rounded()
                value = min(
                    max(range.lowerBound + stepCount * step, range.lowerBound),
                    range.upperBound
                )
            }
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .frame(width: 80, alignment: .leading)

            StretchableSlider(value: steppedValue, range: range)
                .frame(minWidth: 220, maxWidth: .infinity)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        steppedValue.wrappedValue = value + step
                    case .decrement:
                        steppedValue.wrappedValue = value - step
                    @unknown default:
                        break
                    }
                }

            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// SwiftUI's macOS slider keeps its AppKit intrinsic width even inside a wider frame.
/// Hosting NSSlider directly lets the track consume the proposed width instead of centering a
/// short control inside a large invisible box. It also keeps `numberOfTickMarks` at zero —
/// SwiftUI's `Slider(value:in:step:)` draws a row of tick dots under the track for any stepped
/// slider, which reads as a stray grid line. Shared with the pointer pane for that reason.
struct StretchableSlider: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isEnabled = isEnabled
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSSlider,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: nsView.intrinsicContentSize.height
        )
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}
