import AppKit
import SwiftUI

/// Keeps window ordering behind application activation. Ordering an inactive app's window with
/// `orderFrontRegardless` makes it appear above the current app for one frame, then fall behind
/// when WindowServer reconciles activation. Waiting instead gives one stable transition.
enum SettingsWindowPresentationSequence {
    static func perform(
        isApplicationActive: () -> Bool,
        promote: () -> Void,
        orderFront: () -> Void,
        prepareWindow: () -> Void,
        waitForActivation: () -> Void,
        requestActivation: () -> Void
    ) {
        promote()
        if isApplicationActive() {
            orderFront()
        } else {
            prepareWindow()
            waitForActivation()
            requestActivation()
        }
    }
}

/// Creates the settings window in code rather than as a SwiftUI `Settings` scene.
/// `.fullSizeContentView` has to be present in the style mask at construction time for
/// macOS 26 to draw the rounded, translucent window chrome — it cannot be added later.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private lazy var activationLease = AppActivationLease(
        onEnter: { AppActivationPolicy.enter() },
        onLeave: { AppActivationPolicy.leave() }
    )
    private var activationObserver: NSObjectProtocol?
    private var activationRequestPending = false

    static func show(tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        }
        // Opens the draft session before the window exists, so the first thing any pane binds to
        // is already inside a session and no early edit can escape the Save button.
        SettingsStore.shared.beginEditing()
        if shared == nil {
            shared = SettingsWindowController()
        }
        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 760, height: 680)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow() {
        guard let window else { return }
        window.title = Strings.settingsTitle
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("OpenMouseSettingsWindow")
        window.minSize = NSSize(width: 700, height: 520)
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsView())
    }

    override func showWindow(_ sender: Any?) {
        SettingsWindowPresentationSequence.perform(
            isApplicationActive: { NSApp.isActive },
            promote: { activationLease.enter() },
            orderFront: { presentWindow() },
            // A newly promoted LSUIElement app needs an ordered window before WindowServer will
            // honor activation. Normal `orderFront` keeps it behind the current app; unlike
            // `orderFrontRegardless`, it cannot flash above that app before activation.
            prepareWindow: { window?.orderFront(nil) },
            waitForActivation: { waitForApplicationActivation() },
            requestActivation: { requestApplicationActivation() }
        )
    }

    private func requestApplicationActivation() {
        guard !activationRequestPending else { return }
        activationRequestPending = true

        // `setActivationPolicy(.regular)` is reflected by WindowServer asynchronously. Requesting
        // activation in the same stack frame can still be treated as an accessory-app request and
        // ignored. One main-queue turn is enough; the window remains hidden during the wait.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activationRequestPending = false
                // Selecting a status-item command is an explicit user action but not a cooperative
                // activation hand-off from the frontmost app, so the legacy spelling remains the
                // reliable API for LSUIElement utilities on current macOS.
                NSApp.activate(ignoringOtherApps: true)
                if NSApp.isActive {
                    self.presentWindow()
                }
            }
        }
    }

    private func waitForApplicationActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.presentWindow()
            }
        }

        // Close the small race between the active-state check and observer installation.
        if NSApp.isActive {
            presentWindow()
        }
    }

    private func presentWindow() {
        activationRequestPending = false
        stopWaitingForActivation()
        window?.makeKeyAndOrderFront(nil)
    }

    private func stopWaitingForActivation() {
        guard let activationObserver else { return }
        NotificationCenter.default.removeObserver(activationObserver)
        self.activationObserver = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        SettingsLeaveConfirmation.confirm()
    }

    func windowWillClose(_ notification: Notification) {
        stopWaitingForActivation()
        MouseEngine.shared.endButtonCapture()
        // Ends the draft session: anything not saved is reverted here, which is also what makes
        // an unsaved pointer speed spring back instead of outliving the window.
        SettingsStore.shared.endEditing()
        activationLease.leave()
        Self.shared = nil
    }
}
