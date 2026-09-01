import Foundation

/// Thread-safe state shared by the comparison window and the event-tap callback.
///
/// Both comparison panes belong to the Open Mouse process, so application rules alone cannot
/// distinguish them. Hovering a pane selects a temporary policy only for scroll events whose
/// annotated target PID is this process; every other application continues using its normal rule.
final class ScrollComparisonSession: @unchecked Sendable {
    enum Pane: Equatable, Sendable {
        case system
        case openMouse
    }

    enum Mode: Equatable, Sendable {
        case system
        case openMouse(ScrollSettings)
    }

    private struct State {
        var isActive = false
        var hoveredPane: Pane?
        var settings = ScrollSettings.default
    }

    static let shared = ScrollComparisonSession(processID: getpid())

    private let processID: pid_t
    private let state = Locked(State())

    init(processID: pid_t) {
        self.processID = processID
    }

    func begin(settings: ScrollSettings) {
        state.withValue { value in
            value.isActive = true
            value.settings = Self.enabled(settings)
            value.hoveredPane = nil
        }
    }

    func update(settings: ScrollSettings) {
        state.withValue { $0.settings = Self.enabled(settings) }
    }

    @discardableResult
    func setHoveredPane(_ pane: Pane) -> Bool {
        state.withValue { value in
            guard value.isActive, value.hoveredPane != pane else { return false }
            value.hoveredPane = pane
            return true
        }
    }

    @discardableResult
    func clearHoveredPane(_ pane: Pane) -> Bool {
        state.withValue { value in
            guard value.hoveredPane == pane else { return false }
            value.hoveredPane = nil
            return true
        }
    }

    func end() {
        state.value = State()
    }

    func mode(forTargetPID targetPID: pid_t?) -> Mode? {
        guard targetPID == processID else { return nil }
        return state.withValue { value in
            guard value.isActive, let pane = value.hoveredPane else { return nil }
            switch pane {
            case .system:
                return .system
            case .openMouse:
                return .openMouse(value.settings)
            }
        }
    }

    private static func enabled(_ settings: ScrollSettings) -> ScrollSettings {
        var settings = settings.clamped
        settings.smoothingEnabled = true
        return settings
    }
}
