// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// A non-recursive reader/writer lock based on `pthread_rwlock_t`.
final class ReadWriteLock: @unchecked Sendable {
    private var lock = pthread_rwlock_t()

    init() {
        let result = pthread_rwlock_init(&lock, nil)
        precondition(result == 0, "pthread_rwlock_init failed with code \(result)")
    }

    deinit {
        let result = pthread_rwlock_destroy(&lock)
        assert(result == 0)
    }

    /// Acquires a shared read lock for the duration of `work`.
    func withReadLock<T>(_ work: () throws -> T) rethrows -> T {
        let result = pthread_rwlock_rdlock(&lock)
        assert(result == 0)

        defer {
            let result = pthread_rwlock_unlock(&lock)
            assert(result == 0)
        }

        return try work()
    }

    /// Acquires an exclusive write lock for the duration of `work`.
    func withWriteLock<T>(_ work: () throws -> T) rethrows -> T {
        let result = pthread_rwlock_wrlock(&lock)
        assert(result == 0)

        defer {
            let result = pthread_rwlock_unlock(&lock)
            assert(result == 0)
        }

        return try work()
    }
}
