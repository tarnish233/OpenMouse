import AppKit
import Observation

/// Pure scheduling/presentation rules shared by the coordinator and self-checks.
enum UpdatePolicy {
    static let automaticInterval: TimeInterval = 24 * 60 * 60
    static let retryInterval: TimeInterval = 60 * 60

    static func dueDate(lastCheckedAt: Double?, now: Date) -> Date {
        guard let lastCheckedAt else { return now }
        return Date(timeIntervalSince1970: lastCheckedAt + automaticInterval)
    }

    static func isDue(lastCheckedAt: Double?, now: Date) -> Bool {
        dueDate(lastCheckedAt: lastCheckedAt, now: now) <= now
    }

    static func pendingRelease(
        outcome: UpdateChecker.Outcome?,
        skippedVersion: String?
    ) -> UpdateChecker.Release? {
        guard case let .available(release) = outcome,
              release.version != skippedVersion else { return nil }
        return release
    }
}

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
    private var automaticTimer: Timer?
    private var automaticCheckTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var didStartAutomaticScheduling = false
    private var retryNotBefore: Date?

    private init() {}

    /// The release the user should be told about: newer, and not one they chose to skip.
    var pendingRelease: UpdateChecker.Release? {
        UpdatePolicy.pendingRelease(
            outcome: outcome,
            skippedVersion: store.preferences.update.skippedVersion
        )
    }

    /// Start a real-time schedule, not a one-shot launch check. The next due date is restored
    /// from preferences, then re-evaluated after wake and whenever the automatic toggle changes.
    func startAutomaticChecks() {
        guard !didStartAutomaticScheduling else {
            reconcileAutomaticSchedule()
            return
        }
        didStartAutomaticScheduling = true
        restoreKnownRelease()
        observeAutomaticPreference()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileAutomaticSchedule() }
        }
        reconcileAutomaticSchedule()
    }

    private func restoreKnownRelease() {
        let settings = store.preferences.update
        if let last = settings.lastCheckedAt {
            lastCheckedAt = Date(timeIntervalSince1970: last)
        }
        if let known = settings.lastKnownRelease,
           UpdateChecker.isNewer(known.version, than: AppVersion.short) == true {
            outcome = .available(known)
        }
    }

    private func observeAutomaticPreference() {
        withObservationTracking {
            _ = store.preferences.update.checkAutomatically
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileAutomaticSchedule()
                self.observeAutomaticPreference()
            }
        }
    }

    private func reconcileAutomaticSchedule(now: Date = Date()) {
        automaticTimer?.invalidate()
        automaticTimer = nil
        guard store.preferences.update.checkAutomatically else { return }
        guard automaticCheckTask == nil, !isChecking else { return }

        let due = max(
            UpdatePolicy.dueDate(
                lastCheckedAt: store.preferences.update.lastCheckedAt,
                now: now
            ),
            retryNotBefore ?? .distantPast
        )
        guard due > now else {
            launchAutomaticCheck()
            return
        }

        let timer = Timer(timeInterval: due.timeIntervalSince(now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileAutomaticSchedule() }
        }
        automaticTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func launchAutomaticCheck() {
        guard automaticCheckTask == nil, !isChecking else { return }
        automaticCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.check(userInitiated: false)
            self.automaticCheckTask = nil
            self.reconcileAutomaticSchedule()
        }
    }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true

        let result = await UpdateChecker.check(
            repository: UpdateSettings.repository,
            currentVersion: AppVersion.short
        )
        outcome = result
        isChecking = false

        // Only a completed, comparable round trip counts, so a network/parse/version failure
        // does not silence the next automatic check for a whole day.
        switch result {
        case .upToDate:
            let now = Date()
            retryNotBefore = nil
            lastCheckedAt = now
            store.preferences.update.lastCheckedAt = now.timeIntervalSince1970
            store.preferences.update.lastKnownRelease = nil
        case let .available(release):
            let now = Date()
            retryNotBefore = nil
            lastCheckedAt = now
            store.preferences.update.lastCheckedAt = now.timeIntervalSince1970
            store.preferences.update.lastKnownRelease = release
        case .failed, .notConfigured:
            retryNotBefore = Date().addingTimeInterval(UpdatePolicy.retryInterval)
        }

        // A manual check also resets the next real-time wakeup.
        if userInitiated || automaticCheckTask == nil {
            reconcileAutomaticSchedule()
        }
    }

    func skip(_ release: UpdateChecker.Release) {
        store.preferences.update.skippedVersion = release.version
    }

    func open(_ release: UpdateChecker.Release) {
        NSWorkspace.shared.open(release.url)
    }
}
