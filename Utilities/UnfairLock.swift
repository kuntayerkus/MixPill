import Foundation

/// Lightweight unfair lock wrapper for real-time safe synchronization.
/// Faster than NSLock for uncontended access; no priority inversion protection.
/// Use only for short critical sections that never block.
final class UnfairLock: @unchecked Sendable {
    private var lock = os_unfair_lock_s()

    init() {}

    /// Executes `body` while holding the lock.
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return try body()
    }

    /// Executes `body` while holding the lock (void return).
    @inline(__always)
    func withLockVoid(_ body: () throws -> Void) rethrows {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try body()
    }

    /// Attempts to acquire the lock without blocking.
    /// Returns true if acquired, false if already held.
    @inline(__always)
    func tryLock() -> Bool {
        os_unfair_lock_trylock(&lock)
    }
}