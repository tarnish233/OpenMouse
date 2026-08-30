import AppKit
import Observation

/// Owns the on-disk preferences and republishes a `ResolvedConfig` snapshot whenever
/// either the preferences or the frontmost application change.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            scheduleSave()
            refreshSnapshot()
        }
    }

    /// Read by the event tap and the animator from other threads.
    let snapshot = Locked<ResolvedConfig>(.inactive)

    private(set) var frontmostBundleID: String?
    private var saveTask: Task<Void, Never>?
    private let fileURL: URL

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let folder = support.appendingPathComponent("OpenMouse", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("preferences.json")

        let existing = Self.load(from: fileURL)
        var loaded = existing ?? Preferences()
        loaded.normalize()
        preferences = loaded

        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        refreshSnapshot()
        observeActivation()

        // Materialise the file on first launch so "显示配置文件" always has something to
        // reveal, and so the defaults are visible and editable by hand.
        if existing == nil { saveNow() }
    }

    // MARK: Frontmost app tracking

    /// Resolving the frontmost app inside the tap callback would mean an IPC round trip
    /// per scroll event, so we cache it and only invalidate on activation notifications.
    private func observeActivation() {
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
    }

    private func refreshSnapshot() {
        snapshot.value = ResolvedConfig(preferences: preferences, frontmostBundleID: frontmostBundleID)
    }

    // MARK: Persistence

    private static func load(from url: URL) -> Preferences? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [preferences, fileURL] in
            // Sliders fire continuously; coalesce writes.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(preferences) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(preferences) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    var preferencesFileURL: URL { fileURL }

    // MARK: Mutations

    func resetScroll() {
        preferences.scroll = .default
    }

    func resetAll() {
        var fresh = Preferences()
        fresh.normalize()
        preferences = fresh
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
