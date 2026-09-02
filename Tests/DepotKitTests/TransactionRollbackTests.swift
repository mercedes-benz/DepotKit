// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Verifies the commit/rollback semantics of ``Depot/transaction(_:)``:
/// mutations are buffered until the closure returns, discarded entirely on
/// throw, and reads inside the transaction observe the uncommitted buffer.
@Suite("Transaction Rollback")
struct TransactionRollbackTests {
    struct RollbackError: Error {}

    // MARK: - Rollback on throw

    @Test("no values persist after a throwing transaction")
    func rollbackOnThrowNoValuesPersisted() throws {
        let depot = Depot.temporary()
        let keyA = depot.register(keyPath: "a", coder: .json() as AnyCoder<String>)
        let keyB = depot.register(keyPath: "nested" / "b", coder: .json() as AnyCoder<Int>)

        #expect(throws: RollbackError.self) {
            try depot.transaction { transaction in
                try transaction.set(value: "value", for: keyA)
                try transaction.set(value: 42, for: keyB)
                throw RollbackError()
            }
        }

        #expect(try depot.get(valueFor: keyA) == nil)
        #expect(try depot.get(valueFor: keyB) == nil)
        #expect(try depot.has(valueFor: keyA) == false)
    }

    @Test("pre-existing values are unchanged by a rolled-back transaction")
    func rollbackOnThrowExistingValuesUnchanged() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "existing", coder: .json() as AnyCoder<String>)
        try depot.set(value: "original", for: key)

        #expect(throws: RollbackError.self) {
            try depot.transaction { transaction in
                try transaction.set(value: "overwritten", for: key)
                throw RollbackError()
            }
        }

        #expect(try depot.get(valueFor: key) == "original")
    }

    @Test("removals inside a throwing transaction are not applied")
    func rollbackOnThrowRemovalsNotApplied() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "keep", coder: .json() as AnyCoder<String>)
        try depot.set(value: "survivor", for: key)

        #expect(throws: RollbackError.self) {
            try depot.transaction { transaction in
                try transaction.remove(valueFor: key)
                #expect(try transaction.get(valueFor: key) == nil, "removal must be visible inside the transaction")
                throw RollbackError()
            }
        }

        #expect(try depot.get(valueFor: key) == "survivor")
    }

    @Test("removeAll inside a throwing transaction does not wipe the depot")
    func rollbackOnThrowRemoveAllNotApplied() throws {
        let depot = Depot.temporary()
        let keyA = depot.register(keyPath: "a", coder: .json() as AnyCoder<String>)
        let keyB = depot.register(keyPath: "b", coder: .json() as AnyCoder<String>)
        try depot.set(value: "one", for: keyA)
        try depot.set(value: "two", for: keyB)

        #expect(throws: RollbackError.self) {
            try depot.transaction { transaction in
                try transaction.removeAll()
                throw RollbackError()
            }
        }

        #expect(try depot.get(valueFor: keyA) == "one")
        #expect(try depot.get(valueFor: keyB) == "two")
    }

    @Test("rollback semantics apply to memory-only depots")
    func rollbackMemoryOnlyDepot() throws {
        let depot = Depot(label: "MemoryOnly")
        let key = depot.register(keyPath: "value", coder: .json() as AnyCoder<String>)
        try depot.set(value: "original", for: key)

        #expect(throws: RollbackError.self) {
            try depot.transaction { transaction in
                try transaction.set(value: "changed", for: key)
                try transaction.removeAll()
                throw RollbackError()
            }
        }

        #expect(try depot.get(valueFor: key) == "original")
    }

    @Test("async transaction rolls back on throw")
    func rollbackAsyncTransaction() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "async", coder: .json() as AnyCoder<String>)

        await #expect(throws: RollbackError.self) {
            try await depot.transaction { transaction in
                try transaction.set(value: "buffered", for: key)
                throw RollbackError()
            }
        }

        let value = try await depot.get(valueFor: key)
        #expect(value == nil)
    }

    @Test("rolled-back transaction does not pollute the memory cache")
    func rollbackMemoryCacheUnchanged() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "cached", coder: .json() as AnyCoder<String>)
        try depot.set(value: "original", for: key)

        // Warm the cache with the committed value.
        #expect(try depot.get(valueFor: key) == "original")

        #expect(throws: RollbackError.self) {
            try depot.transaction { transaction in
                try transaction.set(value: "poison", for: key)
                throw RollbackError()
            }
        }

        // Both the cached read and a cold read must see the original value.
        #expect(try depot.get(valueFor: key) == "original")
        depot.clearCache()
        #expect(try depot.get(valueFor: key) == "original")
    }

    @Test("no observers are notified for a rolled-back transaction")
    func rollbackObserversNotNotified() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "observed", coder: .json() as AnyCoder<String>)

        let notified = OSAllocatedUnfairLock(initialState: false)
        let stream: AsyncStream<Result<String?, Error>> = depot.values(for: key, initialValue: false)
        let task = Task {
            for await _ in stream {
                notified.withLock { $0 = true }
            }
        }

        #expect(throws: RollbackError.self) {
            try depot.transaction { transaction in
                try transaction.set(value: "never-seen", for: key)
                throw RollbackError()
            }
        }

        await depot.waitForPendingObservations()
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value

        #expect(!notified.withLock { $0 })
    }

    // MARK: - Commit on success

    @Test("values persist after a successful transaction")
    func commitValuesPersistedOnSuccess() throws {
        let depot = Depot.temporary()
        let keyA = depot.register(keyPath: "a", coder: .json() as AnyCoder<String>)
        let keyB = depot.register(keyPath: "b", coder: .json() as AnyCoder<String>)
        try depot.set(value: "obsolete", for: keyB)

        try depot.transaction { transaction in
            try transaction.set(value: "committed", for: keyA)
            try transaction.remove(valueFor: keyB)
        }

        #expect(try depot.get(valueFor: keyA) == "committed")
        #expect(try depot.get(valueFor: keyB) == nil)
    }

    @Test("committed values survive a cache clear (really on disk)")
    func commitWritesToDisk() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "durable", coder: .json() as AnyCoder<String>)

        try depot.transaction { transaction in
            try transaction.set(value: "on-disk", for: key)
        }

        depot.clearCache()
        #expect(try depot.get(valueFor: key) == "on-disk")
    }

    @Test("committed removeAll then set leaves only the new value")
    func commitRemoveAllThenSet() throws {
        let depot = Depot.temporary()
        let keyA = depot.register(keyPath: "a", coder: .json() as AnyCoder<String>)
        let keyB = depot.register(keyPath: "b", coder: .json() as AnyCoder<String>)
        try depot.set(value: "old-a", for: keyA)
        try depot.set(value: "old-b", for: keyB)

        try depot.transaction { transaction in
            try transaction.removeAll()
            try transaction.set(value: "new-a", for: keyA)
        }

        #expect(try depot.get(valueFor: keyA) == "new-a")
        #expect(try depot.get(valueFor: keyB) == nil)
    }

    // MARK: - Overlay reads (uncommitted state visible inside the transaction)

    @Test("get sees a value written earlier in the same transaction")
    func overlayReadSeesBufferedWrite() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 1, for: key)

        try depot.transaction { transaction in
            try transaction.set(value: 2, for: key)
            #expect(try transaction.get(valueFor: key) == 2)
            try transaction.set(value: 3, for: key)
            #expect(try transaction.get(valueFor: key) == 3)
        }

        #expect(try depot.get(valueFor: key) == 3)
    }

    @Test("get returns nil for a value removed in the same transaction")
    func overlayReadSeesBufferedRemove() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "gone", coder: .json() as AnyCoder<String>)
        try depot.set(value: "present", for: key)

        try depot.transaction { transaction in
            try transaction.remove(valueFor: key)
            #expect(try transaction.get(valueFor: key) == nil)
            #expect(try transaction.has(valueFor: key) == false)
        }
    }

    @Test("get returns nil for any key after removeAll in the same transaction")
    func overlayReadSeesRemoveAll() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "wiped", coder: .json() as AnyCoder<String>)
        try depot.set(value: "present", for: key)

        try depot.transaction { transaction in
            try transaction.removeAll()
            #expect(try transaction.get(valueFor: key) == nil)
            #expect(try transaction.has(valueFor: key) == false)
        }
    }

    @Test("pattern get includes buffered writes")
    func overlayPatternReadIncludesBufferedWrites() throws {
        let depot = Depot.temporary()
        let keyA = depot.register(keyPath: "items" / "a", coder: .json() as AnyCoder<String>)
        _ = depot.register(keyPath: "items" / "b", coder: .json() as AnyCoder<String>)
        let pattern = depot.register(
            PatternKeyDefinition<String>(path: "items" / .wildcard, coder: .json()),
        )
        try depot.set(value: "disk-a", for: keyA)

        try depot.transaction { transaction in
            try transaction.set(
                value: "buffered-b",
                for: Key.from("items" / "b", as: String.self),
            )
            let values = try transaction.get(valuesFor: pattern)
            #expect(values.sorted() == ["buffered-b", "disk-a"])
            #expect(try transaction.has(valuesFor: pattern) == true)
        }
    }

    @Test("pattern get excludes tombstoned keys")
    func overlayPatternReadExcludesTombstoned() throws {
        let depot = Depot.temporary()
        let keyA = depot.register(keyPath: "items" / "a", coder: .json() as AnyCoder<String>)
        let keyB = depot.register(keyPath: "items" / "b", coder: .json() as AnyCoder<String>)
        let pattern = depot.register(
            PatternKeyDefinition<String>(path: "items" / .wildcard, coder: .json()),
        )
        try depot.set(value: "disk-a", for: keyA)
        try depot.set(value: "disk-b", for: keyB)

        try depot.transaction { transaction in
            try transaction.remove(valueFor: keyA)
            let values = try transaction.get(valuesFor: pattern)
            #expect(values == ["disk-b"])
        }
    }

    @Test("pattern get with availableValuesFor reflects the overlay")
    func overlayAvailableValuesReflectsBuffer() throws {
        let depot = Depot.temporary()
        let keyA = depot.register(keyPath: "items" / "a", coder: .json() as AnyCoder<String>)
        _ = depot.register(keyPath: "items" / "b", coder: .json() as AnyCoder<String>)
        let pattern = depot.register(
            PatternKeyDefinition<String>(path: "items" / .wildcard, coder: .json()),
        )
        try depot.set(value: "disk-a", for: keyA)

        try depot.transaction { transaction in
            try transaction.remove(valueFor: keyA)
            try transaction.set(
                value: "buffered-b",
                for: Key.from("items" / "b", as: String.self),
            )
            let result = try transaction.get(availableValuesFor: pattern)
            #expect(result.values == ["buffered-b"])
            #expect(result.errors.isEmpty)
        }
    }

    @Test("pattern remove tombstones values buffered in the same transaction")
    func patternRemoveCoversBufferedWrites() throws {
        let depot = Depot.temporary()
        _ = depot.register(keyPath: "items" / "new", coder: .json() as AnyCoder<String>)
        let itemKey = Key.from("items" / "new", as: String.self)

        try depot.transaction { transaction in
            try transaction.set(value: "buffered", for: itemKey)
            try transaction.remove(valuesFor: Key.from("items" / .wildcard))
            #expect(try transaction.get(valueFor: itemKey) == nil)
        }

        #expect(try depot.get(valueFor: itemKey) == nil)
    }

    @Test("I/O failure during commit surfaces as a thrown error")
    func flushFailureSurfacesError() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(component: "TransactionRollbackTests-\(UUID().uuidString)")
        let depot = Depot(configuration: .init(directoryURL: directoryURL, memoryCache: .disabled))
        try depot.verifyIntegrity()
        let key = depot.register(keyPath: "unwritable", coder: .json() as AnyCoder<String>)

        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directoryURL.path(percentEncoded: false)
            )
            try? FileManager.default.removeItem(at: directoryURL)
        }

        #expect(throws: (any Error).self) {
            try depot.transaction { transaction in
                try transaction.set(value: "value", for: key)
                // Writes are buffered — revoking write permission here makes
                // the commit-time flush fail.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o555],
                    ofItemAtPath: directoryURL.path(percentEncoded: false),
                )
            }
        }
    }

    @Test("partial commit failure notifies observers for exactly the applied keys")
    func partialFlushFailureNotifiesAppliedKeys() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(component: "TransactionRollbackTests-\(UUID().uuidString)")
        let depot = Depot(configuration: .init(directoryURL: directoryURL, memoryCache: .disabled))
        try await depot.verifyIntegrity()

        let rootKeys = [
            depot.register(keyPath: "rootA", coder: .json() as AnyCoder<String>),
            depot.register(keyPath: "rootB", coder: .json() as AnyCoder<String>),
            depot.register(keyPath: "rootC", coder: .json() as AnyCoder<String>),
            depot.register(keyPath: "rootD", coder: .json() as AnyCoder<String>),
        ]
        let victimKey = depot.register(keyPath: "locked" / "victim", coder: .json() as AnyCoder<String>)
        try await depot.set(value: "victim", for: victimKey)

        // Path components are base64url-encoded on disk; locate the victim's
        // parent directory by finding the sole subdirectory of the depot.
        let lockedDirectory = try #require(
            try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
            ).first { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true },
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: lockedDirectory.path(percentEncoded: false)
            )
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let notifiedKeys = OSAllocatedUnfairLock(initialState: Set<Int>())
        var tasks = [Task<Void, Never>]()
        for (index, key) in rootKeys.enumerated() {
            let stream: AsyncStream<Result<String?, Error>> = depot.values(for: key, initialValue: false)
            tasks.append(
                Task {
                    for await _ in stream {
                        _ = notifiedKeys.withLock { $0.insert(index) }
                    }
                }
            )
        }

        // Make the victim's directory read-only so its buffered removal fails
        // at commit time. Root-level writes attempted before it still succeed;
        // flush order over the buffer is unspecified, so which subset gets
        // applied varies — the invariant below must hold regardless.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: lockedDirectory.path(percentEncoded: false)
        )

        #expect(throws: (any Error).self) {
            try depot.transaction { transaction in
                for key in rootKeys {
                    try transaction.set(value: "new", for: key)
                }
                try transaction.remove(valueFor: victimKey)
            }
        }

        await depot.waitForPendingObservations()
        try await Task.sleep(for: .milliseconds(50))
        for task in tasks {
            task.cancel()
            await task.value
        }

        // Observers must be in sync with what is visible in storage: a key
        // was notified if and only if its write actually reached disk.
        let notified = notifiedKeys.withLock { $0 }
        for (index, key) in rootKeys.enumerated() {
            let applied = try await depot.get(valueFor: key) == "new"
            #expect(
                notified.contains(index) == applied,
                "observer notification for key \(index) must match its on-disk state (applied: \(applied))",
            )
        }
    }

    @Test("overlay reads in a memory-only depot")
    func overlayReadsMemoryOnly() throws {
        let depot = Depot(label: "MemoryOnly")
        let key = depot.register(keyPath: "value", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 10, for: key)

        try depot.transaction { transaction in
            try transaction.set(value: 20, for: key)
            #expect(try transaction.get(valueFor: key) == 20)
            try transaction.remove(valueFor: key)
            #expect(try transaction.get(valueFor: key) == nil)
        }

        #expect(try depot.get(valueFor: key) == nil)
    }

    // MARK: - Review regression tests

    @Test("observer of a key written after removeAll receives the new value")
    func removeAllThenSetObserverReceivesNewValue() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "rewritten", coder: .json() as AnyCoder<String>)
        try await depot.set(value: "old", for: key)

        let received = OSAllocatedUnfairLock(initialState: [String?]())
        let stream: AsyncStream<Result<String?, Error>> = depot.values(for: key, initialValue: false)
        let task = Task {
            for await result in stream {
                if case let .success(value) = result {
                    received.withLock { $0.append(value) }
                }
            }
        }

        try await depot.transaction { transaction in
            try transaction.remove(valuesFor: Key.all)
            try transaction.set(value: "new", for: key)
        }

        await depot.waitForPendingObservations()
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value

        // Observers re-read the depot, so the removeAll notification must
        // deliver the value rewritten in the same transaction, not nil.
        #expect(received.withLock { $0 } == ["new"])
    }

    @Test("get inside a transaction returns nil when the file vanished behind the cache")
    func getGracefullyHandlesExternallyDeletedFile() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "volatile", coder: .json() as AnyCoder<String>)
        try depot.set(value: "here", for: key)

        // Simulate another process deleting the file (app-group scenario).
        depot.clearCache()
        let fileURL = DistinctKey(key).getFileURL(from: depot.configuration.directoryURL!)
        try FileManager.default.removeItem(at: fileURL)

        try depot.transaction { transaction in
            let value = try transaction.get(valueFor: key)
            let exists = try transaction.has(valueFor: key)
            #expect(value == nil)
            #expect(exists == false)
        }
    }

    @Test("has(valueFor:) inside a transaction reflects buffered state")
    func hasDistinctKeyReflectsBuffer() throws {
        let depot = Depot.temporary()
        let stored = depot.register(keyPath: "stored", coder: .json() as AnyCoder<String>)
        let buffered = depot.register(keyPath: "buffered", coder: .json() as AnyCoder<String>)
        try depot.set(value: "value", for: stored)

        try depot.transaction { transaction in
            #expect(try transaction.has(valueFor: stored) == true)
            #expect(try transaction.has(valueFor: buffered) == false)

            try transaction.set(value: "value", for: buffered)
            #expect(try transaction.has(valueFor: buffered) == true)

            try transaction.remove(valueFor: stored)
            #expect(try transaction.has(valueFor: stored) == false)

            try transaction.remove(valuesFor: Key.all)
            #expect(try transaction.has(valueFor: buffered) == false)
        }
    }

    @Test("partial removeAll failure still notifies observers")
    func partialRemoveAllFailureNotifiesObservers() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(component: "TransactionRollbackTests-\(UUID().uuidString)")
        let depot = Depot(configuration: .init(directoryURL: directoryURL, memoryCache: .disabled))
        try await depot.verifyIntegrity()

        let rootKey = depot.register(keyPath: "root", coder: .json() as AnyCoder<String>)
        let victimKey = depot.register(keyPath: "locked" / "victim", coder: .json() as AnyCoder<String>)
        try await depot.set(value: "root", for: rootKey)
        try await depot.set(value: "victim", for: victimKey)

        let lockedDirectory = try #require(
            try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
            ).first { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true },
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: lockedDirectory.path(percentEncoded: false)
            )
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let receivedValues = OSAllocatedUnfairLock(initialState: [String?]())
        let stream: AsyncStream<Result<String?, Error>> = depot.values(for: rootKey, initialValue: false)
        let task = Task {
            for await result in stream {
                if case let .success(value) = result {
                    receivedValues.withLock { $0.append(value) }
                }
            }
        }

        // The locked subdirectory cannot be emptied, so removeDirectory fails
        // after (possibly) deleting other entries.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: lockedDirectory.path(percentEncoded: false)
        )

        #expect(throws: (any Error).self) {
            try depot.transaction { transaction in
                try transaction.remove(valuesFor: Key.all)
            }
        }

        await depot.waitForPendingObservations()
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value

        // Deletion order is unspecified: the root file may or may not have
        // been removed before the failure. Either way the observer must have
        // been notified and must agree with what a fresh read returns.
        let onDisk = try await depot.get(valueFor: rootKey)
        let received = receivedValues.withLock { $0 }
        #expect(received.count == 1, "observer must be notified exactly once about the partial removeAll")
        #expect(received.last == onDisk, "observed value must match the surviving on-disk state")
    }

    // MARK: - Memory-only pattern operations

    @Test("pattern reads in a memory-only depot transaction observe the overlay")
    func patternReadsMemoryOnly() throws {
        let depot = Depot(label: "MemoryPatternReads")
        let keyA = depot.register(keyPath: "items" / "a", coder: .json() as AnyCoder<String>)
        let keyB = depot.register(keyPath: "items" / "b", coder: .json() as AnyCoder<String>)
        let keyC = depot.register(keyPath: "items" / "c", coder: .json() as AnyCoder<String>)
        let pattern = depot.register(
            PatternKeyDefinition<String>(path: "items" / .wildcard, coder: .json()),
        )
        try depot.set(value: "stored-a", for: keyA)
        try depot.set(value: "stored-b", for: keyB)

        try depot.transaction { transaction in
            try transaction.remove(valueFor: keyA)
            try transaction.set(value: "buffered-c", for: keyC)

            let values = try transaction.get(valuesFor: pattern)
            #expect(values == ["stored-b", "buffered-c"])

            let available = try transaction.get(availableValuesFor: pattern)
            #expect(available.values.sorted() == ["buffered-c", "stored-b"])
            #expect(available.errors.isEmpty)

            let exists = try transaction.has(valuesFor: pattern)
            #expect(exists == true)
        }

        #expect(try depot.get(valueFor: keyA) == nil)
        #expect(try depot.get(valuesFor: pattern).sorted() == ["buffered-c", "stored-b"])
    }

    @Test("pattern has in a memory-only depot transaction honors tombstones")
    func patternHasMemoryOnlyHonorsTombstones() throws {
        let depot = Depot(label: "MemoryPatternHas")
        let keyA = depot.register(keyPath: "items" / "a", coder: .json() as AnyCoder<String>)
        let keyB = depot.register(keyPath: "items" / "b", coder: .json() as AnyCoder<String>)
        let pattern = depot.register(
            PatternKeyDefinition<String>(path: "items" / .wildcard, coder: .json()),
        )
        try depot.set(value: "stored-a", for: keyA)
        try depot.set(value: "stored-b", for: keyB)

        try depot.transaction { transaction in
            try transaction.remove(valueFor: keyA)
            let existsAfterOne = try transaction.has(valuesFor: pattern)
            #expect(existsAfterOne == true, "keyB is still in storage")

            try transaction.remove(valueFor: keyB)
            let existsAfterBoth = try transaction.has(valuesFor: pattern)
            #expect(existsAfterBoth == false, "all matching storage keys are tombstoned")
        }

        #expect(try depot.has(valuesFor: pattern) == false)
    }

    @Test("pattern removal in a memory-only depot transaction covers storage and buffer")
    func patternRemovalMemoryOnly() throws {
        let depot = Depot(label: "MemoryPatternRemove")
        let stored = depot.register(keyPath: "items" / "stored", coder: .json() as AnyCoder<String>)
        let buffered = depot.register(keyPath: "items" / "buffered", coder: .json() as AnyCoder<String>)
        let unrelated = depot.register(keyPath: "other" / "kept", coder: .json() as AnyCoder<String>)
        let pattern = depot.register(
            PatternKeyDefinition<String>(path: "items" / .wildcard, coder: .json()),
        )
        try depot.set(value: "stored", for: stored)
        try depot.set(value: "kept", for: unrelated)

        try depot.transaction { transaction in
            try transaction.set(value: "buffered", for: buffered)
            try transaction.remove(valuesFor: Key.from("items" / .wildcard))

            let values = try transaction.get(valuesFor: pattern)
            #expect(values.isEmpty)
            let unrelatedValue = try transaction.get(valueFor: unrelated)
            #expect(unrelatedValue == "kept")
        }

        #expect(try depot.get(valuesFor: pattern).isEmpty)
        #expect(try depot.get(valueFor: unrelated) == "kept")
    }
}
