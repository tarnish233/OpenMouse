import Foundation
import os.lock

/// Minimal mutex box. The scroll animator runs on its own high-priority queue while
/// preferences are edited on the main thread, so every shared value goes through this.
final class Locked<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = OSAllocatedUnfairLock<Void>(initialState: ())

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { lock.withLock { _ in storage } }
        set { lock.withLock { _ in storage = newValue } }
    }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { _ in body(&storage) }
    }
}
