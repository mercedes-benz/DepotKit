// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// A non-recursive reader/writer lock based on `pthread_rwlock_t`.
///
/// Includes a thread-local re-entrancy guard: attempting to acquire the lock
/// from within an already-held closure triggers a `preconditionFailure` with
/// an actionable message, instead of silently deadlocking. Holding one lock
/// while acquiring a different one is allowed.
///
/// The guard uses a single thread-specific data key shared by all locks, so the
/// number of live locks is not bounded by the process's limit on such keys.
final class ReadWriteLock: @unchecked Sendable {
    /// One lock held by the current thread, linking to the lock it acquired before.
    ///
    /// Each node lives on the stack of the frame that holds the lock, so the thread's
    /// list never outlives the acquisitions it records and needs no cleanup.
    private struct HeldLock {
        let lock: ObjectIdentifier
        let previous: UnsafeMutableRawPointer?
    }

    /// The key whose per-thread value points to the most recently acquired `HeldLock`.
    private static let heldLocksKey: pthread_key_t = {
        var key = pthread_key_t()
        let result = pthread_key_create(&key, nil)
        precondition(result == 0, "pthread_key_create failed with code \(result)")
        return key
    }()

    private var lock = pthread_rwlock_t()
    /// A copy of the shared key, so acquisitions skip the lazy initialization check of the static.
    private let heldLocksKey = ReadWriteLock.heldLocksKey

    init() {
        let result = pthread_rwlock_init(&lock, nil)
        precondition(result == 0, "pthread_rwlock_init failed with code \(result)")
    }

    deinit {
        let result = pthread_rwlock_destroy(&lock)
        precondition(result == 0, "ReadWriteLock operation failed with code \(result)")
    }

    /// Acquires a shared read lock for the duration of `work`.
    func withReadLock<T>(_ work: () throws -> T) rethrows -> T {
        try withHeldLock(exclusive: false, work)
    }

    /// Acquires an exclusive write lock for the duration of `work`.
    func withWriteLock<T>(_ work: () throws -> T) rethrows -> T {
        try withHeldLock(exclusive: true, work)
    }

    /// Checks that the current thread does not hold this lock, acquires it, and records it
    /// as held by the current thread while `work` runs.
    private func withHeldLock<T>(exclusive: Bool, _ work: () throws -> T) rethrows -> T {
        let identity = ObjectIdentifier(self)
        let previous = pthread_getspecific(heldLocksKey)

        var node = previous
        while let current = node {
            let held = current.assumingMemoryBound(to: HeldLock.self).pointee
            precondition(
                held.lock != identity,
                "Depot: re-entrant lock acquisition detected. "
                    + "Inside a transaction closure, use the DepotTransaction parameter "
                    + "instead of calling Depot methods directly.",
            )
            node = held.previous
        }

        let result = exclusive ? pthread_rwlock_wrlock(&lock) : pthread_rwlock_rdlock(&lock)
        precondition(result == 0, "ReadWriteLock operation failed with code \(result)")

        var held = HeldLock(lock: identity, previous: previous)
        return try withUnsafeMutablePointer(to: &held) { pointer in
            pthread_setspecific(heldLocksKey, pointer)

            defer {
                pthread_setspecific(heldLocksKey, previous)
                let result = pthread_rwlock_unlock(&lock)
                precondition(result == 0, "ReadWriteLock operation failed with code \(result)")
            }

            return try work()
        }
    }
}
