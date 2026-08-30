import AppKit
import CoreGraphics
import Observation

/// Wires the preferences to the event tap: decides which events to listen for, starts and
/// stops the tap, and exposes a single status value for the UI to render.
@MainActor
@Observable
final class MouseEngine {
    static let shared = MouseEngine()

    enum Status: Equatable {
        case off
        case needsPermission
        case running
        case failed

        var isRunning: Bool { self == .running }
    }

    private(set) var status: Status = .off
    /// Bumped whenever macOS auto-disables the tap, so the UI can hint at it.
    private(set) var autoReenableCount = 0
    /// A physical press captured while recording: button number plus modifiers held.
    struct CapturedPress: Equatable, Sendable {
        var button: Int
        var modifiers: UInt64
    }

    private(set) var capturedPress: CapturedPress?
    private(set) var isCapturingButton = false

    private let store = SettingsStore.shared
    private let router: EventRouter
    private let tap: EventTapController
    private var permissionPoll: Timer?

    private init() {
        let router = EventRouter(config: store.snapshot)
        self.router = router
        tap = EventTapController { proxy, type, event in
            router.handle(proxy: proxy, type: type, event: event)
        }
        tap.onAutoReenable = { [weak self] in
            MainActor.assumeIsolated { self?.autoReenableCount += 1 }
        }
    }

    // MARK: Lifecycle

    func start() {
        observePreferences()
        apply()
        startPermissionPollIfNeeded()
    }

    func stop() {
        tap.stop()
        router.cancelInFlightScrolling()
        status = .off
    }

    /// Reconcile the tap with the current preferences.
    func apply() {
        let prefs = store.preferences
        router.updateBindings(prefs.buttons)

        guard prefs.enabled || isCapturingButton else {
            tap.stop()
            router.cancelInFlightScrolling()
            status = .off
            return
        }

        guard AccessibilityPermission.isTrusted else {
            tap.stop()
            status = .needsPermission
            startPermissionPollIfNeeded()
            return
        }

        let mask = Self.eventMask(for: prefs, capturingButtons: isCapturingButton)
        status = tap.start(mask: mask) ? .running : .failed
    }

    // MARK: Diagnostics

    /// Snapshot of the live pipeline counters.
    var stats: EngineStats { router.stats.value }

    /// Whether frames are vsync-locked or falling back to a timer.
    var frameSource: DisplayLinkTicker.Source { router.frameSource }

    func resetStats() {
        router.resetStats()
    }

    // MARK: Button learning

    func beginButtonCapture() {
        guard !isCapturingButton else { return }
        isCapturingButton = true
        capturedPress = nil
        router.setCaptureHandler { [weak self] button, modifiers in
            MainActor.assumeIsolated {
                self?.capturedPress = CapturedPress(button: button, modifiers: modifiers)
            }
        }
        apply()
    }

    func endButtonCapture() {
        guard isCapturingButton else { return }
        isCapturingButton = false
        capturedPress = nil
        router.setCaptureHandler(nil)
        apply()
    }

    /// Only subscribe to what the current configuration actually needs — an idle tap on
    /// mouse-moved events would cost CPU on every pointer movement.
    private static func eventMask(for prefs: Preferences, capturingButtons: Bool) -> CGEventMask {
        var mask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        let activeButtons = capturingButtons || prefs.buttons.hasActiveBinding
        if activeButtons {
            mask |= 1 << CGEventType.otherMouseDown.rawValue
            mask |= 1 << CGEventType.otherMouseUp.rawValue
            if EventRouter.needsDragEvents(prefs.buttons) {
                mask |= 1 << CGEventType.otherMouseDragged.rawValue
            }
        }
        return mask
    }

    // MARK: Observation

    private func observePreferences() {
        withObservationTracking {
            _ = store.preferences
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply()
                self.observePreferences()
            }
        }
    }

    /// The system gives no notification when Accessibility is granted, so poll while we
    /// are blocked on it and start the moment it flips.
    private func startPermissionPollIfNeeded() {
        guard permissionPoll == nil, status == .needsPermission else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard AccessibilityPermission.isTrusted else { return }
                timer.invalidate()
                self.permissionPoll = nil
                self.apply()
            }
        }
    }
}
