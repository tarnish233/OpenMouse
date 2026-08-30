import AppKit
import Observation

/// Watches for other running apps that install their own scroll or button event tap.
///
/// Two smoothing engines on one machine fight each other: whichever tap was installed last
/// sits at the head of the chain, swallows the wheel event and posts its own synthetic
/// events, which the other app then sees as a continuous device. Which one wins depends on
/// launch order, so it presents as random misbehaviour rather than as a conflict. Naming the
/// culprit is far kinder than letting the user bisect it.
///
/// Driven by workspace launch/terminate notifications rather than a poll, so the warning
/// appears and disappears on its own at no idle cost.
@MainActor
@Observable
final class ConflictMonitor {
    static let shared = ConflictMonitor()

    struct Conflict: Identifiable, Equatable, Sendable {
        let id: String
        /// The app's own display name, which may be "Mos Debug" rather than "Mos".
        let name: String
    }

    private(set) var conflicts: [Conflict] = []

    private init() {}

    func start() {
        refresh(trigger: "start")
        let center = NSWorkspace.shared.notificationCenter
        // `didTerminate` is the one that clears the warning, and it is not guaranteed: an app
        // that was killed, or that never registered as a GUI app, never sends it. Activation
        // is a cheap extra trigger that covers those — the user has to click *somewhere* after
        // quitting the other app, and this costs nothing while idle.
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.refresh(trigger: note.name.rawValue) }
            }
        }
    }

    /// Re-check on demand, for the moments where a stale warning would be most visible:
    /// opening the menu or the settings window.
    func refreshNow() {
        refresh(trigger: "manual")
    }

    private func refresh(trigger: String) {
        let ourBundleID = Bundle.main.bundleIdentifier
        let running: [(bundleID: String, name: String)] = NSWorkspace.shared.runningApplications
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != ourBundleID else { return nil }
                return (id, app.localizedName ?? id)
            }
        let found = Self.conflicts(among: running)
        guard found != conflicts else { return }
        conflicts = found
        Trace.conflicts(found.map(\.name), trigger: trigger)
    }

    // MARK: Matching (pure, so it can be checked without a live conflict)

    /// Bundle identifier prefixes of apps known to tap scroll or mouse-button events.
    /// Prefix matching catches debug and beta builds such as `com.caldis.Mos.debug`.
    nonisolated static let known: [(prefix: String, product: String)] = [
        ("com.caldis.Mos", "Mos"),
        ("com.lujjjh.LinearMouse", "LinearMouse"),
        ("com.nuebling.mac-mouse-fix", "Mac Mouse Fix"),
        ("com.pilotmoon.scroll-reverser", "Scroll Reverser"),
        ("com.plentycom.SteerMouse", "SteerMouse"),
        ("com.hobbyistsoftware.osx.BetterTouchTool", "BetterTouchTool"),
        ("com.folivora.BetterTouchTool", "BetterTouchTool"),
        ("com.logi.optionsplus", "Logi Options+"),
        ("com.logitech.manager", "Logitech Options"),
        ("com.smoothscroll", "SmoothScroll")
    ]

    /// One entry per product, so "Mos" and "Mos Debug" do not both shout at the user.
    nonisolated static func conflicts(among running: [(bundleID: String, name: String)]) -> [Conflict] {
        var found: [String: Conflict] = [:]
        for app in running {
            guard let match = known.first(where: { app.bundleID.hasPrefix($0.prefix) }) else { continue }
            found[match.product] = Conflict(id: match.product, name: app.name)
        }
        return found.values.sorted { $0.name < $1.name }
    }
}
