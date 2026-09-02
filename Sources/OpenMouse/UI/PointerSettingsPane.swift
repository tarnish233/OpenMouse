import AppKit
import SwiftUI

/// Per-device pointer speed.
///
/// Devices are listed and checked rather than detected and applied automatically: the HID event
/// system's mouse filter also matches keyboards and virtual pointing devices, and nothing it
/// exposes separates them reliably (see `PointerSpeedController.mouseServices`). Letting the
/// user pick turns an unsolvable classification problem into one checkbox.
struct PointerSettingsPane: View {
    @State private var store = SettingsStore.shared
    @State private var controller = PointerSpeedController.shared

    private var rows: [PointerSpeedController.Row] {
        PointerSpeedController.rows(
            discovered: controller.discovered,
            settings: store.preferences.pointer
        )
    }

    var body: some View {
        Form {
            Section {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label(Strings.pointerEmpty, systemImage: "cursorarrow.motionlines")
                    } description: {
                        Text(Strings.pointerEmptyBody)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                } else {
                    ForEach(rows) { row in
                        PointerDeviceRow(
                            row: row,
                            state: controller.states[row.key] ?? .disabled,
                            isEnabled: enabledBinding(for: row),
                            acceleration: accelerationBinding(for: row)
                        )
                        // An expanded row ends with the slider, and the list's own separator
                        // right under it boxed the slider into what looked like its own table
                        // cell instead of part of the device above.
                        .listRowSeparator(isExpanded(row) ? .hidden : .automatic)
                    }
                }
            } header: {
                Text(Strings.pointerSectionTitle)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Strings.pointerIntro)
                    Text(Strings.pointerCurveNote)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button(Strings.pointerRestoreDefaults) {
                    controller.restoreSystemDefaults()
                }
                .disabled(rows.isEmpty)
            } footer: {
                Text(Strings.pointerRestoreDefaultsHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear { controller.reconcile() }
    }

    // MARK: Bindings

    /// A row exists for every connected device, but a *stored* device only appears once the user
    /// enables it — so checking the box is what creates the record.
    private func enabledBinding(for row: PointerSpeedController.Row) -> Binding<Bool> {
        Binding(
            get: { store.preferences.pointer.device(for: row.key)?.enabled ?? false },
            set: { isOn in
                if let index = index(of: row) {
                    store.preferences.pointer.devices[index].enabled = isOn
                    // Refresh the remembered name while the device is here to be named; it is
                    // the only thing that identifies the row once it goes offline.
                    if !row.name.isEmpty {
                        store.preferences.pointer.devices[index].name = row.name
                    }
                } else if isOn {
                    store.preferences.pointer.devices.append(
                        PointerSpeedDevice(
                            vendorID: row.key.vendorID,
                            productID: row.key.productID,
                            name: row.name,
                            enabled: true
                        )
                    )
                }
            }
        )
    }

    private func accelerationBinding(for row: PointerSpeedController.Row) -> Binding<Double> {
        Binding(
            get: {
                store.preferences.pointer.device(for: row.key)?.acceleration
                    ?? PointerSpeed.systemDefault
            },
            set: { value in
                guard let index = index(of: row) else { return }
                store.preferences.pointer.devices[index].acceleration = PointerSpeed.clamped(value)
            }
        )
    }

    private func index(of row: PointerSpeedController.Row) -> Int? {
        store.preferences.pointer.devices.firstIndex { $0.key == row.key }
    }

    /// An enabled row grows a slider below its name, which is what makes its trailing separator
    /// land in the wrong place.
    private func isExpanded(_ row: PointerSpeedController.Row) -> Bool {
        store.preferences.pointer.device(for: row.key)?.enabled == true
    }
}

private struct PointerDeviceRow: View {
    let row: PointerSpeedController.Row
    let state: PointerSpeedController.ApplyState
    @Binding var isEnabled: Bool
    @Binding var acceleration: Double

    /// A device that is present but has no acceleration property can never be steered, so the
    /// checkbox is disabled rather than offered and then silently ignored.
    private var canBeEnabled: Bool {
        !row.isLive || row.supportsAcceleration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The state text sits *before* the switch so every switch lands on the same right
            // edge. After it, a long label shoved one row's switch inward, which reads as a
            // layout bug rather than as information.
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name.isEmpty ? Strings.pointerUnnamedDevice : row.name)
                    Text(Strings.pointerDeviceIdentity(row.key.vendorID, row.key.productID))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                if let label = state.label {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(state.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        // Never let the switch squeeze this: a half-clipped reason is worse than
                        // no reason, because it looks like a rendering glitch instead of a state.
                        .lineLimit(1)
                        .fixedSize()
                        .help(state.help ?? "")
                }

                Toggle(isOn: $isEnabled) {
                    // Hidden visually, kept for VoiceOver: once the name moves to the leading
                    // column the switch would otherwise be unnamed.
                    Text(row.name.isEmpty ? Strings.pointerUnnamedDevice : row.name)
                }
                .labelsHidden()
                .disabled(!canBeEnabled)
            }

            if isEnabled {
                HStack(spacing: 10) {
                    Text(Strings.pointerValueTitle)
                        .foregroundStyle(.secondary)
                    StretchableSlider(value: snappedAcceleration, range: sliderBounds)
                        .frame(minWidth: 180, maxWidth: .infinity)
                        .accessibilityLabel(Strings.pointerValueTitle)
                        .accessibilityValue(Strings.pointerValue(acceleration))
                    TextField(
                        Strings.pointerValueTitle,
                        value: $acceleration,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .labelsHidden()
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                }
                .font(.callout)
                Text(Strings.pointerSystemDefaultHint(PointerSpeed.systemDefault))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var sliderBounds: ClosedRange<Double> {
        PointerSpeed.sliderBounds(for: acceleration)
    }

    /// The numeric field writes the raw value; only the slider snaps. Sharing one binding would
    /// make the field unable to express anything between two slider steps.
    private var snappedAcceleration: Binding<Double> {
        Binding(
            get: { acceleration },
            set: { acceleration = PointerSpeed.snapped($0, within: sliderBounds) }
        )
    }
}
