import AppKit
import Observation

/// Owns update-check state for the UI: what the last check found, whether one is in flight,
/// and the once-a-day automatic check.
@MainActor
@Observable
final class UpdateCoordinator {
    static let shared = UpdateCoordinator()

    private(set) var outcome: UpdateChecker.Outcome?
    private(set) var isChecking = false
    private(set) var lastCheckedAt: Date?

    private var store: SettingsStore { SettingsStore.shared }
    /// Re-check no more than once a day; a menu bar utility has no business hitting the API
    /// on every launch.
    private let automaticInterval: TimeInterval = 24 * 60 * 60

    private init() {}

    /// The release the user should be told about: newer, and not one they chose to skip.
    var pendingRelease: UpdateChecker.Release? {
        guard case let .available(release) = outcome else { return nil }
        guard release.version != store.preferences.update.skippedVersion else { return nil }
        return release
    }

    func startAutomaticCheckIfDue() {
        let settings = store.preferences.update
        guard settings.checkAutomatically else { return }

        // Show what the last check found before deciding whether to make a new request, so
        // the notice is present immediately on launch rather than only after a round trip.
        if let known = settings.lastKnownRelease,
           UpdateChecker.isNewer(known.version, than: AppVersion.short) {
            outcome = .available(known)
        }

        if let last = settings.lastCheckedAt,
           Date().timeIntervalSince1970 - last < automaticInterval {
            lastCheckedAt = Date(timeIntervalSince1970: last)
            return
        }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let result = await UpdateChecker.check(
            repository: UpdateSettings.repository,
            currentVersion: AppVersion.short
        )
        outcome = result

        // Only a completed round trip counts, so a network failure does not silence the
        // next automatic check for a whole day.
        switch result {
        case .upToDate:
            let now = Date()
            lastCheckedAt = now
            store.preferences.update.lastCheckedAt = now.timeIntervalSince1970
            store.preferences.update.lastKnownRelease = nil
        case let .available(release):
            let now = Date()
            lastCheckedAt = now
            store.preferences.update.lastCheckedAt = now.timeIntervalSince1970
            store.preferences.update.lastKnownRelease = release
        case .failed, .notConfigured:
            break
        }
    }

    func skip(_ release: UpdateChecker.Release) {
        store.preferences.update.skippedVersion = release.version
    }

    func open(_ release: UpdateChecker.Release) {
        NSWorkspace.shared.open(release.url)
    }
}
