import Foundation

/// Encodes and writes debounced preference snapshots away from the main/event-tap run loop.
enum PreferencesSaveWorker {
    static func encodedData(for preferences: Preferences) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(preferences)
    }

    static func schedule(
        preferences: Preferences,
        delay: Duration = .milliseconds(400),
        write: @escaping @Sendable (Data) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let data = encodedData(for: preferences),
                  !Task.isCancelled else { return }
            write(data)
        }
    }
}
