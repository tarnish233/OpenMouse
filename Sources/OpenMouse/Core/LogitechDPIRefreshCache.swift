import Foundation

/// Session-scoped freshness metadata; the observable DPI value already lives in MouseEngine.
/// Never persist this to preferences: reconnecting creates a cold cache for the new device.
struct LogitechDPIRefreshCache {
    static let freshnessInterval: TimeInterval = 10
    static let retryInterval: TimeInterval = 5

    private var refreshedAt: TimeInterval?
    private var failedAt: TimeInterval?
    private var unsupported = false

    func needsRefresh(at now: TimeInterval) -> Bool {
        guard !unsupported else { return false }
        if let failedAt {
            return now < failedAt || now - failedAt >= Self.retryInterval
        }
        guard let refreshedAt else { return true }
        return now < refreshedAt || now - refreshedAt >= Self.freshnessInterval
    }

    mutating func recordSuccess(at now: TimeInterval) {
        refreshedAt = now
        failedAt = nil
        unsupported = false
    }

    mutating func recordFailure(at now: TimeInterval) {
        failedAt = now
    }

    mutating func markUnsupported() {
        unsupported = true
    }
}
