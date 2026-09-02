import AppKit
import Darwin
import Observation
import OpenMouseUpdateSupport

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

    /// The release that is being withheld only because it was skipped. Surfacing it is what gives
    /// "跳过此版本" a way back: without this the choice is permanent and invisible.
    static func skippedRelease(
        outcome: UpdateChecker.Outcome?,
        skippedVersion: String?
    ) -> UpdateChecker.Release? {
        guard case let .available(release) = outcome,
              let skippedVersion,
              release.version == skippedVersion else { return nil }
        return release
    }

    /// Whether a finished check should retire the post-install notice.
    ///
    /// The outcome row renders `installationState` ahead of the check result, and the relaunch after
    /// an in-app update sets it to `.installed(version)` with nothing ever resetting it. So the
    /// "已更新到 X" banner masked every later finding — including the install button for a newer
    /// release — which meant **in-app updating disabled itself after its first successful use**.
    /// Observed on 0.7.0 → 0.7.1: the check ran and found 0.7.1 (the "上次检查" timestamp advanced)
    /// while the UI kept saying 已更新到 0.7.0.
    ///
    /// Retired when the result is something the user must be able to act on, or when they asked for
    /// this check themselves. An *automatic* check that merely confirms "still current" leaves the
    /// notice alone, so the confirmation does not vanish a second after the update that earned it.
    static func shouldRetireInstallationNotice(
        state: UpdateCoordinator.InstallationState,
        result: UpdateChecker.Outcome,
        userInitiated: Bool
    ) -> Bool {
        switch state {
        // Nothing to retire, or an install is still in flight and owns the row.
        case .idle, .downloading, .installing:
            return false
        case .installed, .failed:
            break
        }
        if userInitiated { return true }
        if case .available = result { return true }
        return false
    }
}

/// Owns update-check state for the UI: what the last check found, whether one is in flight,
/// and the once-a-day automatic check.
@MainActor
@Observable
final class UpdateCoordinator {
    enum InstallationState: Equatable {
        case idle
        case downloading(String)
        case installing(String)
        case installed(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .installing: true
            case .idle, .installed, .failed: false
            }
        }
    }

    static let shared = UpdateCoordinator()

    private static let terminationGrace = UpdateHandoff.terminationGrace

    private(set) var outcome: UpdateChecker.Outcome?
    private(set) var isChecking = false
    private(set) var lastCheckedAt: Date?
    private(set) var installationState: InstallationState = .idle
    let canInstallAutomatically: Bool

    private var store: SettingsStore { SettingsStore.shared }
    private var automaticTimer: Timer?
    private var automaticCheckTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var didStartAutomaticScheduling = false
    private var retryNotBefore: Date?
    private var terminationFallback: Timer?

    private init() {
        canInstallAutomatically = UpdateCodeSignature.supportsAutomaticInstallation(
            at: Bundle.main.bundleURL
        )
    }

    /// The release the user should be told about: newer, and not one they chose to skip.
    var pendingRelease: UpdateChecker.Release? {
        UpdatePolicy.pendingRelease(
            outcome: outcome,
            skippedVersion: store.preferences.update.skippedVersion
        )
    }

    /// A newer release currently hidden by "跳过此版本", so the UI can offer to unhide it.
    var skippedRelease: UpdateChecker.Release? {
        UpdatePolicy.skippedRelease(
            outcome: outcome,
            skippedVersion: store.preferences.update.skippedVersion
        )
    }

    /// Restores the result passed back by the independent updater after it relaunches us.
    func consumeUpdaterLaunchResult(arguments: [String] = CommandLine.arguments) {
        if let version = Self.argumentValue(after: "--update-installed", in: arguments) {
            installationState = .installed(version)
            outcome = .upToDate(current: version)
            store.preferences.update.lastKnownRelease = nil
            store.preferences.update.skippedVersion = nil
        } else if let message = Self.argumentValue(after: "--update-error", in: arguments) {
            installationState = .failed(message)
        }
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
        guard automaticCheckTask == nil, !isChecking, !installationState.isBusy else { return }

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
        guard automaticCheckTask == nil, !isChecking, !installationState.isBusy else { return }
        automaticCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.check(userInitiated: false)
            self.automaticCheckTask = nil
            self.reconcileAutomaticSchedule()
        }
    }

    func check(userInitiated: Bool) async {
        guard !isChecking, !installationState.isBusy else { return }
        isChecking = true

        let result = await UpdateChecker.check(
            repository: UpdateSettings.repository,
            currentVersion: AppVersion.short
        )
        outcome = result
        isChecking = false
        if UpdatePolicy.shouldRetireInstallationNotice(
            state: installationState,
            result: result,
            userInitiated: userInitiated
        ) {
            installationState = .idle
        }

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
        guard !installationState.isBusy else { return }
        store.preferences.update.skippedVersion = release.version
    }

    func clearSkip() {
        guard !installationState.isBusy else { return }
        store.preferences.update.skippedVersion = nil
    }

    func install(_ release: UpdateChecker.Release) async {
        guard !installationState.isBusy else { return }
        installationState = .downloading(release.version)

        do {
            let prepared = try await UpdateInstaller.prepare(
                release: release,
                repository: UpdateSettings.repository,
                currentBundleURL: Bundle.main.bundleURL
            )
            installationState = .installing(prepared.version)
            store.saveNow()
            try UpdateInstaller.launch(prepared, parentPID: getpid())
            // Armed before asking to quit, and on .common so it still fires from a modal loop:
            // `terminate` is a request the app or a modal panel can refuse. Without this the
            // .installing state — and therefore `isBusy` — would stick for the rest of the
            // process, short-circuiting every future check while the UI kept spinning.
            armTerminationFallback()
            NSApp.terminate(nil)
        } catch {
            installationState = .failed(error.localizedDescription)
            reconcileAutomaticSchedule()
        }
    }

    private func armTerminationFallback() {
        terminationFallback?.invalidate()
        let timer = Timer(
            timeInterval: Self.terminationGrace,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromRefusedTermination() }
        }
        terminationFallback = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Still running well past the quit request, so the swap will not happen. The helper gives the
    /// parent 30s before it gives up, so this deliberately fires earlier: the user learns why
    /// nothing happened while the helper is still waiting, rather than after it has bailed out.
    private func recoverFromRefusedTermination() {
        terminationFallback = nil
        guard case .installing = installationState else { return }
        installationState = .failed(Strings.updateQuitRefused)
        reconcileAutomaticSchedule()
    }

    func open(_ release: UpdateChecker.Release) {
        NSWorkspace.shared.open(release.url)
    }

    private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
