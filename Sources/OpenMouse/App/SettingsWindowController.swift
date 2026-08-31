import AppKit
import SwiftUI

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

    static func show(tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        }
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
        // Promote the activation policy *before* ordering the window front: a `.accessory`
        // app cannot own the active window, so activating first would be a no-op.
        activationLease.enter()
        super.showWindow(sender)
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // The policy change lands on the next run-loop turn, and until it does the window
        // can end up behind whatever was frontmost. Re-asserting once afterwards is cheap
        // and makes "设置…" reliably bring the window forward.
        Task { @MainActor in
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        MouseEngine.shared.endButtonCapture()
        SettingsStore.shared.saveNow()
        activationLease.leave()
        Self.shared = nil
    }
}
