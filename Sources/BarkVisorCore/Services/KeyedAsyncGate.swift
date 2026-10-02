import Foundation

/// Non-reentrant async mutex keyed by string, used to serialize a short critical section per
/// subject (see `VMLifecycleService.deleteVM`, where accept + replay-check + submit must be
/// atomic per workload).
///
/// Actor isolation alone is not enough here: an `await` inside a critical section re-enters the
/// actor, so two callers would interleave exactly where the section must not.
public final class KeyedAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func withLock<T>(_ key: String, _ body: () async throws -> T) async rethrows -> T {
        await acquire(key)
        defer { release(key) }
        return try await body()
    }

    private func acquire(_ key: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if held.contains(key) {
                waiters[key, default: []].append(continuation)
                lock.unlock()
            } else {
                held.insert(key)
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func release(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var queue = waiters[key], !queue.isEmpty else {
            held.remove(key)
            return
        }
        let next = queue.removeFirst()
        if queue.isEmpty {
            waiters.removeValue(forKey: key)
        } else {
            waiters[key] = queue
        }
        next.resume()
    }
}
