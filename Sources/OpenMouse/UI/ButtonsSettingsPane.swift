import AppKit
import SwiftUI

/// Buttons are *recorded*, not enumerated: press the button you want, a row appears for it,
/// then choose what it does. Which buttons a mouse reports varies by device, so a fixed list
/// of "middle plus four side buttons" would show rows for hardware that isn't there and hide
/// buttons that are.
struct ButtonsSettingsPane: View {
    @State private var store = SettingsStore.shared
    @State private var isRecording = false
    @State private var highlightedID: UUID?

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
                            onRemove: { remove(binding) }
                        )
                    }
                    Button {
                        isRecording = true
                    } label: {
                        Label(Strings.buttonsRecord, systemImage: "plus")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
            } header: {
                Text(Strings.buttonsSectionTitle)
            } footer: {
                Text(Strings.buttonsIntro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
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
        let binding = ButtonBinding(button: press.button, modifiers: press.modifiers)
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
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ButtonBadge(button: binding.button, modifiers: binding.modifiers)
                .overlay {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.tint, lineWidth: 2)
                    }
                }

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)

            ActionRow(action: $binding.action)

            Button(role: .destructive) { onRemove() } label: {
                Image(systemName: "minus.circle")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help(Strings.buttonsRemove)
        }
        .padding(.vertical, 2)
    }
}

/// The "from" half of a mapping, rendered like a key cap.
private struct ButtonBadge: View {
    let button: Int
    let modifiers: UInt64

    var body: some View {
        HStack(spacing: 3) {
            if modifiers != 0 {
                Text(KeyCodeNames.modifierGlyphs(modifiers))
                    .font(.system(size: 12, weight: .medium))
            }
            Text(Strings.buttonName(button))
                .font(.system(size: 12, weight: .medium))
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        .frame(minWidth: 96, alignment: .leading)
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

private struct ActionRow: View {
    @Binding var action: MouseAction

    private var kind: Binding<ActionKind> {
        Binding(
            get: { ActionKind(action) },
            set: { action = $0.makeAction(preserving: action) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // A flat picker with two dozen actions is an unusable ribbon of text. Grouping
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
                Text(ActionKind(action).title)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            switch action {
            case .keyStroke:
                ShortcutRecorderView(combo: comboBinding)
            case let .launchApp(path):
                HStack(spacing: 8) {
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
