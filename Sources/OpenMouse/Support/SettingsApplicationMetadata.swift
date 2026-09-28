import AppKit

/// Only immutable display values cross back to the main actor. No workspace IPC or disk
/// lookup is performed from a SwiftUI body; a serial utility queue bounds concurrent IO.
@MainActor
enum SettingsApplicationMetadata {
    private static let queue = DispatchQueue(label: "com.openmouse.settings-metadata", qos: .utility)

    static let icons = SettingsMetadataCache<String, NSImage>(lifetime: 60, missingLifetime: 10) {
        bundleID, complete in
        queue.async {
            let image: NSImage? = autoreleasepool {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                    return nil
                }
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            DispatchQueue.main.async { complete(image) }
        }
    }

    static let names: SettingsMetadataCache<Int, String> = {
        let cache = SettingsMetadataCache<Int, String>(lifetime: 5, missingLifetime: 1, capacity: 64) {
            pid, complete in
            queue.async {
                let name = pid > 0 ? NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName : nil
                DispatchQueue.main.async { complete(name) }
            }
        }
        // These observers live for the process-wide cache, not just while General is visible.
        // Only previously requested PIDs are re-read; unrelated app launches cost no lookup.
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: event, object: nil, queue: .main) { [weak cache] note in
                MainActor.assumeIsolated {
                    guard let cache,
                          let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    let pid = Int(app.processIdentifier)
                    guard cache.contains(pid) else { return }
                    cache.invalidate(pid)
                    cache.refresh(pid)
                }
            }
        }
        return cache
    }()
}
