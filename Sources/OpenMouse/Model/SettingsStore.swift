import AppKit
import Observation

/// Owns the on-disk preferences and republishes a `ResolvedConfig` snapshot whenever
/// either the preferences or the frontmost application change.
@MainActor
@Observable
final class SettingsStore {
    nonisolated static let productionBundleIdentifier = "com.openmouse.OpenMouse"
    nonisolated static let debugBundleIdentifier = "com.openmouse.OpenMouse.debug"
    static let shared = SettingsStore()

    /// Debug bundles must never share the production preferences file. Besides keeping test data
    /// disposable, this prevents a stale test process from overwriting the user's real mappings.
    nonisolated static func applicationSupportFolderName(bundleIdentifier: String?) -> String {
        bundleIdentifier == debugBundleIdentifier ? "OpenMouse Debug" : "OpenMouse"
    }

    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            scrollRules.updatePreferences(preferences)
            scheduleSave()
            refreshSnapshot()
        }
    }

    /// Read by the event tap and the animator from other threads.
    let snapshot = Locked<ResolvedConfig>(.inactive)
    /// Resolves scroll rules from the event's annotated target pid without IPC in the tap.
    let scrollRules = ScrollRuleResolver()

    /// The last saved state of the draft sections, held only while the settings window is open.
    ///
    /// `preferences` always stays the live state — that is what makes an unsaved change something
    /// you can actually feel — so the draft is tracked by remembering what disk should still say.
    private(set) var savedDraft: DraftSections?

    var hasUnsavedChanges: Bool {
        guard let savedDraft else { return false }
        return savedDraft != DraftSections(preferences)
    }

    private(set) var frontmostBundleID: String?
    private var saveTask: Task<Void, Never>?
    private let fileURL: URL

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let folderName = Self.applicationSupportFolderName(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        let folder = support.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("preferences.json")

        let existing = Self.load(from: fileURL)
        var loaded = existing ?? Preferences()
        loaded.normalize()
        preferences = loaded
        scrollRules.updatePreferences(loaded)
        scrollRules.replaceApplications(NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return (pid: app.processIdentifier, bundleID: bundleID)
        })

        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        refreshSnapshot()
        observeWorkspace()

        // Materialise the file on first launch so "显示配置文件" always has something to
        // reveal, and so the defaults are visible and editable by hand.
        if existing == nil { saveNow() }
    }

    // MARK: Frontmost app tracking

    /// Resolving the frontmost app inside the tap callback would mean an IPC round trip
    /// per scroll event, so we cache it and only invalidate on activation notifications.
    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.frontmostBundleID = app?.bundleIdentifier
                self?.refreshSnapshot()
            }
        }
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app else { return }
            MainActor.assumeIsolated {
                self?.scrollRules.applicationDidLaunch(
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier
                )
            }
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app else { return }
            MainActor.assumeIsolated {
                self?.scrollRules.applicationDidTerminate(pid: app.processIdentifier)
            }
        }
    }

    private func refreshSnapshot() {
        snapshot.value = ResolvedConfig(preferences: preferences, bundleID: frontmostBundleID)
    }

    // MARK: Persistence

    private static func load(from url: URL) -> Preferences? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    /// What belongs on disk right now: the live values for everything that applies immediately,
    /// but the last *saved* values for the draft sections. Without this the 400 ms autosave would
    /// quietly persist a draft the user never committed, and "只有点击保存才算数" would be a lie
    /// the moment the app restarted.
    private var persistedPreferences: Preferences {
        savedDraft?.applied(to: preferences) ?? preferences
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let preferences = persistedPreferences
        let fileURL = fileURL
        saveTask = PreferencesSaveWorker.schedule(preferences: preferences) { data in
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let data = PreferencesSaveWorker.encodedData(for: persistedPreferences) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    var preferencesFileURL: URL { fileURL }

    // MARK: Editing session

    /// Opens a draft session, which the settings window owns for as long as it is on screen.
    /// Idempotent: reopening the window must not adopt the current draft as the saved state.
    func beginEditing() {
        guard savedDraft == nil else { return }
        savedDraft = DraftSections(preferences)
    }

    func saveEdits() {
        savedDraft = DraftSections(preferences)
        saveNow()
    }

    /// Puts the live state back to what was last saved. Assigning `preferences` is what makes the
    /// revert perceptible — the tap snapshot and the pointer controller both follow it — so a
    /// discarded pointer speed springs back rather than lingering until relaunch.
    func discardEdits() {
        guard let savedDraft, hasUnsavedChanges else { return }
        preferences = savedDraft.applied(to: preferences)
    }

    func endEditing() {
        discardEdits()
        savedDraft = nil
        saveNow()
    }

    // MARK: Mutations

    func resetScroll() {
        preferences.scroll = .default
    }

    func resetAll() {
        var fresh = Preferences()
        fresh.normalize()
        preferences = fresh
        // An explicit "reset everything" is not a draft. Leaving half of it pending behind the
        // Save button would make that button's meaning depend on which section you looked at.
        commitImmediately()
    }

    /// The status menu's "disable for this app" is a menu action, not an editing gesture: it must
    /// stick whether or not the settings window happens to be open behind it.
    func toggleBypassRule(bundleID: String, name: String) {
        preferences.toggleBypassRule(bundleID: bundleID, name: name)
        commitImmediately()
    }

    /// Folds the current live state into the saved baseline, so a mutation made outside the
    /// settings window is not left looking like an unsaved edit.
    private func commitImmediately() {
        if savedDraft != nil { savedDraft = DraftSections(preferences) }
        saveNow()
    }

    func updateBinding(_ binding: ButtonBinding) {
        guard let index = preferences.buttons.firstIndex(where: { $0.button == binding.button }) else { return }
        preferences.buttons[index] = binding
    }

    func addRule(bundleID: String, name: String) {
        guard !preferences.rules.contains(where: { $0.bundleID == bundleID }) else { return }
        var rule = AppRule(bundleID: bundleID, name: name)
        rule.scroll = preferences.scroll
        preferences.rules.append(rule)
    }

    func removeRules(ids: Set<UUID>) {
        preferences.rules.removeAll { ids.contains($0.id) }
    }
}
