import Foundation
import Observation

/// Small session-only, stale-while-revalidate cache for display metadata, never preferences.
/// Reading a value does no work. The injected loader must enqueue IO and reply on MainActor.
@MainActor
@Observable
final class SettingsMetadataCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value?
        var expiresAt: TimeInterval
        var order: UInt64
    }

    private var entries: [Key: Entry] = [:]
    @ObservationIgnored private var pending: [Key: UUID] = [:]
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private let lifetime: TimeInterval
    @ObservationIgnored private let missingLifetime: TimeInterval
    @ObservationIgnored private let capacity: Int
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let load: (Key, @escaping (Value?) -> Void) -> Void

    init(
        lifetime: TimeInterval,
        missingLifetime: TimeInterval = 5,
        capacity: Int = 128,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        load: @escaping (Key, @escaping (Value?) -> Void) -> Void
    ) {
        self.lifetime = lifetime
        self.missingLifetime = missingLifetime
        self.capacity = max(1, capacity)
        self.now = now
        self.load = load
    }

    func value(for key: Key) -> Value? { entries[key]?.value }
    func revision(for key: Key) -> UInt64? { entries[key]?.order }

    func contains(_ key: Key) -> Bool { entries[key] != nil || pending[key] != nil }

    func refresh(_ key: Key, force: Bool = false) {
        guard pending[key] == nil else { return }
        if !force, let entry = entries[key], now() < entry.expiresAt { return }
        let id = UUID()
        pending[key] = id
        load(key) { [weak self] value in
            guard let self, self.pending[key] == id else { return }
            self.pending[key] = nil
            self.sequence &+= 1
            self.entries[key] = Entry(
                value: value,
                expiresAt: self.now() + (value == nil ? self.missingLifetime : self.lifetime),
                order: self.sequence
            )
            if self.entries.count > self.capacity,
               let oldest = self.entries.min(by: { $0.value.order < $1.value.order })?.key {
                self.entries[oldest] = nil
            }
        }
    }

    /// In-flight results from the previous identity must not repopulate an invalidated key
    /// (notably when the OS reuses the PID of a terminated application).
    func invalidate(_ key: Key) {
        pending[key] = nil
        entries[key] = nil
    }
}
