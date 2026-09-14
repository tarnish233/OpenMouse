import AppKit

/// One decision path for sidebar navigation, window closing, and application termination.
/// A modal alert keeps the original pane alive until the user has resolved its live draft.
@MainActor
enum SettingsLeaveConfirmation {
    private static var isPresenting = false

    static func confirm() -> Bool {
        guard !isPresenting else { return false }
        let store = SettingsStore.shared
        guard store.hasUnsavedChanges else { return true }
        isPresenting = true
        defer { isPresenting = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.settingsUnsavedTitle
        alert.informativeText = Strings.settingsUnsavedMessage
        alert.addButton(withTitle: Strings.settingsSave)
        alert.addButton(withTitle: Strings.settingsDontSave).keyEquivalent = "d"
        alert.buttons[1].keyEquivalentModifierMask = [.command]
        alert.addButton(withTitle: Strings.settingsLeaveCancel).keyEquivalent = "\u{1b}"
        return resolve(
            alert.runModal(),
            save: { store.saveEdits() },
            discard: { store.discardEdits() }
        )
    }

    static func resolve(
        _ response: NSApplication.ModalResponse,
        save: () -> Void,
        discard: () -> Void
    ) -> Bool {
        switch response {
        case .alertFirstButtonReturn:
            save()
            return true
        case .alertSecondButtonReturn:
            discard()
            return true
        default:
            return false
        }
    }
}
