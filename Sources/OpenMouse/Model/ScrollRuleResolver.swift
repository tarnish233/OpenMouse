import Foundation

/// Thread-safe rule snapshot used by the event-tap callback.
///
/// Resolving a target pid through `NSRunningApplication` inside the callback would add IPC to
/// the hottest path. The main actor therefore maintains this pid → bundle-id table from
/// workspace lifecycle notifications, while the callback performs only one lock-protected
/// value lookup and pure preference resolution.
final class ScrollRuleResolver: @unchecked Sendable {
    private struct State {
        var preferences = Preferences()
        var bundleIDsByPID: [pid_t: String] = [:]
    }

    private let state = Locked(State())

    func updatePreferences(_ preferences: Preferences) {
        state.withValue { $0.preferences = preferences }
    }

    func replaceApplications(_ applications: [(pid: pid_t, bundleID: String)]) {
        state.withValue { value in
            value.bundleIDsByPID = Dictionary(
                applications.map { ($0.pid, $0.bundleID) },
                uniquingKeysWith: { _, newest in newest }
            )
        }
    }

    func applicationDidLaunch(pid: pid_t, bundleID: String?) {
        state.withValue { value in
            guard let bundleID, !bundleID.isEmpty else {
                value.bundleIDsByPID[pid] = nil
                return
            }
            value.bundleIDsByPID[pid] = bundleID
        }
    }

    func applicationDidTerminate(pid: pid_t) {
        state.withValue { $0.bundleIDsByPID[pid] = nil }
    }

    func resolve(targetPID: pid_t?) -> ResolvedConfig {
        state.withValue { value in
            let bundleID = targetPID.flatMap { value.bundleIDsByPID[$0] }
            return ResolvedConfig(preferences: value.preferences, bundleID: bundleID)
        }
    }

    func bundleID(for pid: pid_t) -> String? {
        state.withValue { $0.bundleIDsByPID[pid] }
    }
}
