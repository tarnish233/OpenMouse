import AppKit
import SwiftUI

/// Buttons are *recorded*, not enumerated: press the button you want, a row appears for it,
/// then choose what it does. Which buttons a mouse reports varies by device, so a fixed list
/// of "middle plus four side buttons" would show rows for hardware that isn't there and hide
/// buttons that are.
struct ButtonsSettingsPane: View {
    @State private var store = SettingsStore.shared
    @State private var engine = MouseEngine.shared
    @State private var isRecording = false
    @State private var highlightedID: UUID?
    @State private var showsRecordingHelp = false

    var body: some View {
        Form {
            PermissionBanner()

            Section {
                if store.preferences.buttons.isEmpty {
                    ContentUnavailableView {
                        Label(Strings.buttonsEmptyTitle, systemImage: "computermouse")
                    } description: {
                        Text(Strings.buttonsEmptyBody)
                    } actions: {
                        Button(Strings.buttonsRecord) { isRecording = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                } else {
                    ForEach($store.preferences.buttons) { $binding in
                        BindingRow(
                            binding: $binding,
                            isHighlighted: highlightedID == binding.id,
                            currentDPI: engine.currentLogitechDPI,
                            onRemove: { remove(binding) }
                        )
                    }
                }
            } header: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(Strings.buttonsSectionTitle)
                            if !store.preferences.buttons.isEmpty {
                                Text(Strings.buttonsMappingCount(store.preferences.buttons.count))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(Strings.buttonsIntro)
                            .font(.caption)
                            .fontWeight(.regular)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !store.preferences.buttons.isEmpty {
                        Button { isRecording = true } label: {
                            Label(Strings.buttonsRecord, systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .fixedSize()
                    }
                }
                .textCase(nil)
            } footer: {
                DisclosureGroup(isExpanded: $showsRecordingHelp) {
                    Text(Strings.buttonsRecordingHelp)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } label: {
                    Text(Strings.buttonsRecordingHelpTitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        // Render the engine's cached DPI immediately; a stale value is refreshed asynchronously.
        .onAppear { engine.refreshLogitechDPI() }
        .sheet(isPresented: $isRecording) {
            ButtonRecorderSheet { press in
                add(press)
            }
        }
    }

    private func add(_ press: MouseEngine.CapturedPress) {
        // Re-recording an existing combination should point at the row that already exists
        // rather than creating a second, shadowed binding.
        if let existing = store.preferences.buttons.first(where: {
            $0.button == press.button && $0.modifiers == press.modifiers
        }) {
            highlightedID = existing.id
            return
        }
        let defaultAction: MouseAction = press.button == LogitechHIDPPProtocol.dpiSwitchButton
            ? .toggleDPI(.default)
            : .passthrough
        let binding = ButtonBinding(
            button: press.button,
            modifiers: press.modifiers,
            action: defaultAction
        )
        store.preferences.buttons.append(binding)
        store.preferences.buttons.sort { ($0.button, $0.modifiers) < ($1.button, $1.modifiers) }
        highlightedID = binding.id
    }

    private func remove(_ binding: ButtonBinding) {
        store.preferences.buttons.removeAll { $0.id == binding.id }
    }
}

// MARK: - One recorded binding

private struct BindingRow: View {
    @Binding var binding: ButtonBinding
    let isHighlighted: Bool
    let currentDPI: Int?
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ButtonBadge(button: binding.button, modifiers: binding.modifiers)
                .overlay {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(.tint, lineWidth: 2)
                    }
                }

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(height: 32)
                .accessibilityHidden(true)

            ActionEditor(action: $binding.action, currentDPI: currentDPI)

            Button(role: .destructive) { onRemove() } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(Strings.buttonsRemove)
            .accessibilityLabel(Strings.buttonsRemove)
        }
        .padding(.vertical, 8)
    }
}

/// The "from" half of a mapping, rendered like a key cap.
private struct ButtonBadge: View {
    let button: Int
    let modifiers: UInt64

    var body: some View {
        VStack(spacing: 2) {
            if modifiers != 0 {
                Text(KeyCodeNames.modifierGlyphs(modifiers))
                    .font(.system(size: 11, weight: .medium))
            }
            Text(Strings.buttonName(button))
                .font(.system(size: 12, weight: .semibold))
        }
        .monospacedDigit()
        .frame(width: 88)
        .frame(minHeight: 32)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recorder sheet

private struct ButtonRecorderSheet: View {
    let onCapture: (MouseEngine.CapturedPress) -> Void

    @State private var engine = MouseEngine.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "computermouse")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)

            Text(Strings.recorderTitle)
                .font(.headline)

            if let press = engine.capturedPress {
                VStack(spacing: 4) {
                    Text(Strings.recorderCaptured)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        if press.modifiers != 0 {
                            Text(KeyCodeNames.modifierGlyphs(press.modifiers))
                        }
                        Text(Strings.buttonName(press.button))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 7))
                }
            } else {
                Text(Strings.recorderHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(Strings.recorderCancel) { finish(commit: false) }
                    .keyboardShortcut(.cancelAction)
                Button(Strings.recorderConfirm) { finish(commit: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.capturedPress == nil)
            }
            .controlSize(.regular)
        }
        .padding(24)
        .frame(width: 340)
        .onAppear { engine.beginButtonCapture() }
        .onDisappear { engine.endButtonCapture() }
    }

    private func finish(commit: Bool) {
        if commit, let press = engine.capturedPress {
            onCapture(press)
        }
        dismiss()
    }
}

// MARK: - Action picker with payload editors

private struct ActionEditor: View {
    @Binding var action: MouseAction
    let currentDPI: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A flat picker with dozens of actions is an unusable ribbon of text. Grouping
            // them into submenus keeps the whole list two clicks away and one screen tall,
            // with the default sitting at the top level where it is one click.
            Menu {
                ForEach(ActionKind.ungrouped) { item in
                    row(for: item)
                }
                Divider()
                ForEach(ActionKind.groups, id: \.0) { group in
                    Menu(group.0) {
                        ForEach(group.1) { item in
                            row(for: item)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(ActionKind(action).title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            // Plain button style preserves the full-width label; the AppKit borderless
            // menu style extracts its title/image and discards the custom layout.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(Strings.buttonsAction)
            .accessibilityValue(ActionKind(action).title)

            switch action {
            case let .toggleDPI(levels):
                DPIToggleEditor(
                    levels: levelsBinding(levels),
                    currentDPI: currentDPI
                )
            case .gestureNavigation:
                Text(Strings.buttonsGestureHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .keyStroke:
                ShortcutRecorderView(combo: comboBinding)
            case let .launchApp(path):
                VStack(alignment: .leading, spacing: 6) {
                    Button(Strings.buttonChooseApp) { chooseApp() }
                        .controlSize(.small)
                    Text(path.isEmpty ? Strings.buttonNoAppChosen : (path as NSString).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(path.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for item: ActionKind) -> some View {
        Button {
            action = item.makeAction(preserving: action)
        } label: {
            if ActionKind(action) == item {
                Label(item.title, systemImage: "checkmark")
            } else {
                Text(item.title)
            }
        }
    }

    private var comboBinding: Binding<KeyCombo?> {
        Binding(
            get: {
                if case let .keyStroke(combo) = action { return combo.valueIfSet }
                return nil
            },
            set: { newValue in
                guard let newValue else { return }
                action = .keyStroke(newValue)
            }
        )
    }

    private func levelsBinding(_ fallback: LogitechDPILevels) -> Binding<LogitechDPILevels> {
        Binding(
            get: {
                if case let .toggleDPI(levels) = action { return levels }
                return fallback
            },
            set: { action = .toggleDPI($0) }
        )
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        action = .launchApp(path: url.path)
    }
}

private struct DPIToggleEditor: View {
    @Binding var levels: LogitechDPILevels
    let currentDPI: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Strings.dpiLowerLevel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DPIValueMenu(
                        value: levels.lower,
                        choices: lowerChoices,
                        currentDPI: currentDPI,
                        onSelect: { levels = LogitechDPILevels(lower: $0, upper: levels.upper) }
                    )
                }
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(Strings.dpiUpperLevel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DPIValueMenu(
                        value: levels.upper,
                        choices: upperChoices,
                        currentDPI: currentDPI,
                        onSelect: { levels = LogitechDPILevels(lower: levels.lower, upper: $0) }
                    )
                }
            }
            .frame(maxWidth: 280, alignment: .leading)

            Text(currentDPI.map(Strings.dpiCurrentValue) ?? Strings.dpiCurrentUnknown)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var lowerChoices: [Int] {
        LogitechDPILevels.choices.filter { $0 < levels.upper }
    }

    private var upperChoices: [Int] {
        LogitechDPILevels.choices.filter { $0 > levels.lower }
    }
}

private struct DPIValueMenu: View {
    let value: Int
    let choices: [Int]
    let currentDPI: Int?
    let onSelect: (Int) -> Void

    private var isCurrent: Bool { currentDPI == value }

    var body: some View {
        menu
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .background(
                isCurrent ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04),
                in: .rect(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isCurrent ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }
            .help(isCurrent ? Strings.dpiCurrentHelp(value) : Strings.dpiChangeHelp)
            .accessibilityLabel(Strings.dpiValue(value))
            .accessibilityValue(
                currentDPI == nil
                    ? Strings.dpiCurrentUnknown
                    : (isCurrent ? Strings.dpiCurrentAccessibilityValue : Strings.dpiInactiveAccessibilityValue)
            )
    }

    private var menu: some View {
        Menu {
            ForEach(choices, id: \.self) { choice in
                Button {
                    onSelect(choice)
                } label: {
                    if choice == value {
                        Label(Strings.dpiValue(choice), systemImage: "checkmark")
                    } else {
                        Text(Strings.dpiValue(choice))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: Strings.dpiValue(value))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}
