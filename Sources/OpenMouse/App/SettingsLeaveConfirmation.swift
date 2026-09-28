import AppKit

/// Owns one leave request through both the queued presentation and the user's decision.
/// Injected scheduling/presentation lets self-checks exercise the asynchronous lifecycle,
/// rather than merely testing the three button return values.
@MainActor
final class SettingsLeaveCoordinator {
    typealias Reply = (NSApplication.ModalResponse) -> Void
    private let hasUnsavedChanges: () -> Bool
    private let save: () -> Void
    private let discard: () -> Void
    private let enqueue: (@escaping () -> Void) -> Void
    private var pendingID: UUID?
    var isPending: Bool { pendingID != nil }

    init(
        hasUnsavedChanges: @escaping () -> Bool,
        save: @escaping () -> Void,
        discard: @escaping () -> Void,
        enqueue: @escaping (@escaping () -> Void) -> Void
    ) {
        self.hasUnsavedChanges = hasUnsavedChanges
        self.save = save
        self.discard = discard
        self.enqueue = enqueue
    }

    /// False means another request already owns the confirmation; its action must not be
    /// replaced or replayed as a different action (for example Quit during a page change).
    @discardableResult
    func request(
        present: @escaping (@escaping Reply) -> Void,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard !isPending else { return false }
        guard hasUnsavedChanges() else {
            completion(true)
            return true
        }
        let id = UUID()
        pendingID = id
        // Never present a modal UI inside SwiftUI's List selection / Binding writeback.
        enqueue { [weak self] in
            guard let self, self.pendingID == id else { return }
            guard self.hasUnsavedChanges() else {
                self.pendingID = nil
                completion(true)
                return
            }
            present { [weak self] response in
                guard let self, self.pendingID == id else { return }
                // AppKit detaches a sheet after its completion handler returns. Closing
                // the parent inside that handler can be ignored while it still owns a sheet.
                self.enqueue { [weak self] in
                    guard let self, self.pendingID == id else { return }
                    let shouldLeave = SettingsLeaveConfirmation.resolve(
                        response, save: self.save, discard: self.discard
                    )
                    self.pendingID = nil
                    completion(shouldLeave)
                }
            }
        }
        return true
    }
}

/// Shared by sidebar/history navigation, window closing, and application termination.
/// A window-attached asynchronous sheet keeps the draft alive without nesting a modal
/// run loop in a SwiftUI update (the hidden runModal alert caused the v0.7.6 UI hang).
@MainActor
enum SettingsLeaveConfirmation {
    private static let coordinator = SettingsLeaveCoordinator(
        hasUnsavedChanges: { SettingsStore.shared.hasUnsavedChanges },
        save: { SettingsStore.shared.saveEdits() },
        discard: { SettingsStore.shared.discardEdits() },
        enqueue: { operation in
            DispatchQueue.main.async { MainActor.assumeIsolated { operation() } }
        }
    )

    static var isPending: Bool { coordinator.isPending }

    @discardableResult
    static func request(completion: @escaping (Bool) -> Void) -> Bool {
        request(on: SettingsWindowController.confirmationWindow, completion: completion)
    }

    @discardableResult
    static func request(on window: NSWindow?, completion: @escaping (Bool) -> Void) -> Bool {
        coordinator.request(present: { [weak window] reply in
            // No detached/app-modal fallback: if the owner has gone away or already has a
            // sheet, cancel this leave attempt without saving or throwing away the draft.
            guard let window, window.isVisible, window.attachedSheet == nil else {
                reply(.abort)
                return
            }
            let alert = makeAlert()
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { reply(response) }
            }
        }, completion: completion)
    }

    private static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.settingsUnsavedTitle
        alert.informativeText = Strings.settingsUnsavedMessage
        alert.addButton(withTitle: Strings.settingsSave)
        alert.addButton(withTitle: Strings.settingsDontSave).keyEquivalent = "d"
        alert.buttons[1].keyEquivalentModifierMask = [.command]
        alert.addButton(withTitle: Strings.settingsLeaveCancel).keyEquivalent = "\u{1b}"
        return alert
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
