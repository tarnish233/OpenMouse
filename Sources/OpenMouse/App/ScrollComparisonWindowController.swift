import AppKit
import SwiftUI

/// Owns the standalone side-by-side scroll comparison window.
@MainActor
final class ScrollComparisonWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: ScrollComparisonWindowController?
    private lazy var activationLease = AppActivationLease(
        onEnter: { AppActivationPolicy.enter() },
        onLeave: { AppActivationPolicy.leave() }
    )
    private var activationObserver: NSObjectProtocol?
    private var activationRequestPending = false

    static func show() {
        if shared == nil {
            shared = ScrollComparisonWindowController()
        }
        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 860, height: 600)),
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
        window.title = Strings.scrollComparisonTitle
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("OpenMouseScrollComparisonWindow")
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ScrollComparisonView())
    }

    override func showWindow(_ sender: Any?) {
        MouseEngine.shared.beginScrollComparison(settings: SettingsStore.shared.preferences.scroll)
        SettingsWindowPresentationSequence.perform(
            isApplicationActive: { NSApp.isActive },
            promote: { activationLease.enter() },
            orderFront: { presentWindow() },
            prepareWindow: { window?.orderFront(nil) },
            waitForActivation: { waitForApplicationActivation() },
            requestActivation: { requestApplicationActivation() }
        )
    }

    private func requestApplicationActivation() {
        guard !activationRequestPending else { return }
        activationRequestPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activationRequestPending = false
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

    func windowWillClose(_ notification: Notification) {
        stopWaitingForActivation()
        MouseEngine.shared.endScrollComparison()
        activationLease.leave()
        Self.shared = nil
    }
}
