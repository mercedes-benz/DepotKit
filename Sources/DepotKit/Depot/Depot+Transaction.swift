// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

extension Depot {
    /// A buffered mutation recorded inside a transaction.
    ///
    /// Nothing touches the underlying storage until ``Depot/Transaction/flush()``
    /// materializes the buffer after the transaction closure returns successfully.
    enum PendingMutation {
        /// A pending write. Holds the typed value for overlay reads, the encoded
        /// payload (`nil` in memory-only mode, where no coder is involved), and
        /// the key's expiry duration resolved at write time.
        case write(value: any Sendable, encodedData: Data?, expiry: Duration?)

        /// A pending removal (tombstone).
        case remove
    }

    /// The concrete transaction implementation backing ``DepotTransaction``.
    ///
    /// Mutations accumulate in ``pendingMutations`` (write-ahead buffer). Reads
    /// consult the buffer first (overlay) and fall through to storage. On
    /// success the buffer is flushed to storage; on throw it is discarded,
    /// leaving the depot untouched.
    struct Transaction: DepotTransactionOps {
        private let depot: Depot

        /// Buffered mutations, keyed by the affected key. Later mutations to
        /// the same key overwrite earlier ones (last-write-wins).
        private(set) var pendingMutations = [DistinctKey: PendingMutation]()

        /// Pattern removals that matched no keys, preserved for observer
        /// notification parity with non-transactional `remove(valuesFor:)`.
        private(set) var emptyPatternRemovals = [Key]()

        /// Whether `removeAll()` (or removal of `Key.all`) was requested.
        private(set) var pendingRemoveAll = false

        private(set) var needsPruneEmptyDirectories = false
        private(set) var needsTouchLock = false

        // MARK: - Outcome Bookkeeping

        /// Keys whose writes have been materialized to storage by ``flush()``.
        ///
        /// Populated during the flush so that observers can be told exactly
        /// what changed — including the partially applied subset when the
        /// flush fails midway.
        private(set) var appliedModifiedKeys = Set<DistinctKey>()

        /// Keys whose removals have been materialized to storage by ``flush()``.
        private(set) var appliedRemovedKeys = Set<DistinctKey>()

        /// Whether a pending `removeAll()` has been materialized by ``flush()``.
        private(set) var appliedRemoveAll = false

        init(depot: Depot) {
            self.depot = depot
        }

        // MARK: - Reads (buffer overlay → storage)

        func get<V>(valueFor key: some TypedDistinctKeyProtocol<V>) throws -> V? where V: Sendable {
            guard key.components != depot.metadataKey.components else {
                throw DepotError.reservedKey(keyPath: key.keyPath)
            }

            let distinctKey = DistinctKey(key)

            switch pendingMutations[distinctKey] {
            case let .write(value, _, _):
                return try cast(value, for: distinctKey)
            case .remove:
                return nil
            case nil:
                break
            }

            if pendingRemoveAll {
                return nil
            }

            return try getFromStorage(valueFor: distinctKey)
        }

        func get<V>(valuesFor key: some TypedKeyProtocol<V>) throws -> [V] where V: Sendable {
            var keyedValues = try storageValues(matching: key) { _, error in
                throw error
            }

            for (distinctKey, mutation) in pendingMutations where key.matches(distinctKey) {
                switch mutation {
                case let .write(value, _, _):
                    keyedValues[distinctKey] = try cast(value, for: distinctKey) as V
                case .remove:
                    keyedValues.removeValue(forKey: distinctKey)
                }
            }

            return
                keyedValues
                .sorted { $0.key < $1.key }
                .map(\.value)
        }

        func get<V>(availableValuesFor key: some TypedKeyProtocol<V>) throws -> AvailableValuesResult<V>
        where V: Sendable {
            var keyedErrors = [DistinctKey: any Error & Sendable]()
            var keyedValues: [DistinctKey: V] = try storageValues(matching: key) { distinctKey, error in
                keyedErrors[distinctKey] = error
            }

            for (distinctKey, mutation) in pendingMutations where key.matches(distinctKey) {
                keyedValues.removeValue(forKey: distinctKey)
                keyedErrors.removeValue(forKey: distinctKey)

                switch mutation {
                case let .write(value, _, _):
                    do {
                        keyedValues[distinctKey] = try cast(value, for: distinctKey) as V
                    } catch {
                        keyedErrors[distinctKey] = DepotError.mismatchedTypes(
                            keyPath: distinctKey.keyPath,
                            expected: "\(V.self)",
                            actual: "\(type(of: value))",
                        )
                    }
                case .remove:
                    break
                }
            }

            return AvailableValuesResult(keyedValues: keyedValues, keyedErrors: keyedErrors)
        }

        func has(valuesFor key: some KeyProtocol) throws -> Bool {
            // Distinct keys can be answered with a single buffer lookup.
            if let distinctKey = try? key.distinct() {
                switch pendingMutations[distinctKey] {
                case .write:
                    return true
                case .remove:
                    return false
                case nil:
                    if pendingRemoveAll {
                        return false
                    }
                    return try storageHas(valuesFor: key, tombstonedKeys: [])
                }
            }

            var tombstonedKeys = Set<DistinctKey>()
            for (distinctKey, mutation) in pendingMutations where key.matches(distinctKey) {
                switch mutation {
                case .write:
                    return true
                case .remove:
                    tombstonedKeys.insert(distinctKey)
                }
            }

            if pendingRemoveAll {
                return false
            }

            return try storageHas(valuesFor: key, tombstonedKeys: tombstonedKeys)
        }

        func count(for key: some KeyProtocol) throws -> Int {
            var tombstonedKeys = Set<DistinctKey>()
            var bufferedWriteKeys = Set<DistinctKey>()

            for (distinctKey, mutation) in pendingMutations where key.matches(distinctKey) {
                switch mutation {
                case .write:
                    bufferedWriteKeys.insert(distinctKey)
                case .remove:
                    tombstonedKeys.insert(distinctKey)
                }
            }

            if pendingRemoveAll {
                return bufferedWriteKeys.count
            }

            let storageCount = try storageCount(
                for: key,
                tombstonedKeys: tombstonedKeys,
                bufferedWriteKeys: bufferedWriteKeys,
            )
            return bufferedWriteKeys.count + storageCount
        }

        // MARK: - Writes (buffer only, no storage I/O)

        mutating func set<V>(value: V?, for key: some TypedDistinctKeyProtocol<V>) throws where V: Sendable {
            guard !depot.configuration.readOnly else {
                throw DepotError.readOnlyDepot
            }

            guard key.components != depot.metadataKey.components else {
                throw DepotError.reservedKey(keyPath: key.keyPath)
            }

            let distinctKey = DistinctKey(key)

            guard let value else {
                pendingMutations[distinctKey] = .remove
                return
            }

            // Memory-only path: no coder involved, store the typed value directly.
            if depot.memoryEntries != nil {
                pendingMutations[distinctKey] = .write(
                    value: value,
                    encodedData: nil,
                    expiry: depot.core.expiry(for: distinctKey),
                )
                return
            }

            // File-backed path: encode eagerly so coder failures abort (and roll
            // back) the transaction at the `set` call site.
            let (coder, expiry) = try depot.core.coderAndExpiry(for: distinctKey.key, as: V.self)
            pendingMutations[distinctKey] = .write(
                value: value,
                encodedData: try coder.encode(value),
                expiry: expiry,
            )
        }

        mutating func remove(valuesFor key: some KeyProtocol) throws {
            guard !depot.configuration.readOnly else {
                throw DepotError.readOnlyDepot
            }

            if key.components == [.globstar] {
                pendingMutations.removeAll()
                emptyPatternRemovals.removeAll()
                pendingRemoveAll = true
                return
            }

            if let distinctKey = try? key.distinct() {
                pendingMutations[distinctKey] = .remove
                return
            }

            // Pattern removal: tombstone buffered writes matching the pattern
            // plus all keys currently present in storage.
            var affectedKeys = Set<DistinctKey>()

            for (distinctKey, mutation) in pendingMutations where key.matches(distinctKey) {
                if case .write = mutation {
                    affectedKeys.insert(distinctKey)
                }
            }

            if !pendingRemoveAll {
                if let memoryEntries = depot.memoryEntries {
                    let storageKeys = memoryEntries.withLock { entries in
                        entries.keys.filter { key.matches($0) }
                    }
                    affectedKeys.formUnion(storageKeys)
                } else {
                    let storageKeys = try depot.fileManager!.files(for: key).map(\.key)
                    affectedKeys.formUnion(storageKeys)
                }
            }

            if affectedKeys.isEmpty {
                emptyPatternRemovals.append(Key(key))
            } else {
                for distinctKey in affectedKeys {
                    pendingMutations[distinctKey] = .remove
                }
            }
        }

        // MARK: - Flush (materialize buffer on commit)

        /// Applies all buffered mutations to the underlying storage.
        ///
        /// Called exactly once, after the transaction closure returns without
        /// throwing. If flushing itself throws (for example the disk is full),
        /// the raw error is rethrown and the depot may be left with only part
        /// of the transaction applied — the same exposure as a crash between
        /// individual writes. Each file is still written atomically, so no
        /// single value can be corrupted. The applied subset is tracked in
        /// ``appliedModifiedKeys``/``appliedRemovedKeys`` so observers can be
        /// notified about exactly what reached storage.
        mutating func flush() throws {
            if let memoryEntries = depot.memoryEntries {
                flushToMemory(memoryEntries)
            } else {
                try flushToDisk()
            }
        }

        private mutating func flushToMemory(_ memoryEntries: OSAllocatedUnfairLock<[DistinctKey: MemoryEntry]>) {
            let now = depot.clock.now()
            let mutations = pendingMutations
            let removeAll = pendingRemoveAll
            memoryEntries.withLock { entries in
                if removeAll {
                    entries.removeAll()
                }
                for (distinctKey, mutation) in mutations {
                    switch mutation {
                    case let .write(value, _, expiry):
                        entries[distinctKey] = MemoryEntry(
                            value: value,
                            modifiedAt: now,
                            expiresAt: expiry.map { now.addingTimeInterval($0.timeInterval) },
                        )
                    case .remove:
                        entries.removeValue(forKey: distinctKey)
                    }
                }
            }
            appliedRemoveAll = removeAll
            for (distinctKey, mutation) in mutations {
                switch mutation {
                case .write:
                    appliedModifiedKeys.insert(distinctKey)
                case .remove:
                    appliedRemovedKeys.insert(distinctKey)
                }
            }
        }

        private mutating func flushToDisk() throws {
            if pendingRemoveAll {
                do {
                    try depot.fileManager!.removeDirectory(
                        at: depot.configuration.directoryURL!,
                        skipHiddenFiles: false,
                    )
                } catch {
                    // The directory is removed item by item, so a failure may
                    // leave it partially deleted. Conservatively report the
                    // removeAll anyway: observers are pull-based and re-read
                    // the surviving state, and the cache must not serve
                    // entries for files that are already gone.
                    depot.memoryCache?.removeAll()
                    depot.changeTracker?.removed(key: Key.all)
                    appliedRemoveAll = true
                    throw error
                }
                depot.changeTracker?.removed(key: Key.all)
                appliedRemoveAll = true

                do {
                    try depot.checkMetadata(createIfNeeded: true)
                } catch {
                    LOG(
                        level: .error,
                        message: "Depot[\(depot.label)] failed to verify its integrity due to error \(error)",
                    )
                }

                depot.memoryCache?.removeAll()
                needsTouchLock = true
            }

            // A single commit timestamp for all mutations in the transaction.
            let now = depot.clock.now()

            for (distinctKey, mutation) in pendingMutations {
                let fileURL = distinctKey.getFileURL(from: depot.configuration.directoryURL!)

                switch mutation {
                case let .write(value, encodedData, expiry):
                    guard let encodedData else {
                        preconditionFailure(
                            "File-backed transaction buffered a write without encoded data for key '\(distinctKey.keyPath)'",
                        )
                    }
                    try flushWrite(
                        value: value,
                        encodedData: encodedData,
                        expiry: expiry,
                        for: distinctKey,
                        at: fileURL,
                        now: now
                    )
                    appliedModifiedKeys.insert(distinctKey)
                case .remove:
                    try depot.fileManager!.removeItem(at: fileURL)
                    depot.changeTracker?.removed(key: distinctKey)
                    depot.memoryCache?.remove(valuesFor: distinctKey)
                    appliedRemovedKeys.insert(distinctKey)
                    needsPruneEmptyDirectories = true
                }

                needsTouchLock = true
            }
        }

        private func flushWrite(
            value: any Sendable,
            encodedData: Data,
            expiry: Duration?,
            for distinctKey: DistinctKey,
            at fileURL: URL,
            now: Date,
        ) throws {
            let expiresAt = expiry.map { now.addingTimeInterval($0.timeInterval) }
            let header = FileHeader(modifiedAt: now, expiresAt: expiresAt, crc32: CRC32.checksum(encodedData))
            let fileData = header.serialized() + encodedData

            try depot.fileManager!.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try fileData.write(to: fileURL, options: .atomic)

            let modificationDate = depot.updateResourceValues(at: fileURL)
            depot.changeTracker?.modified(key: distinctKey, at: modificationDate)
            depot.memoryCache?.set(
                value: value,
                for: distinctKey,
                cost: fileData.count,
                expiresAt: expiresAt,
            )
        }

        // MARK: - Storage Reads (committed state, unaware of the buffer)

        private func cast<V>(_ value: any Sendable, for distinctKey: DistinctKey) throws -> V {
            guard let value = value as? V else {
                throw DepotError.mismatchedTypes(
                    keyPath: distinctKey.keyPath,
                    expected: "\(V.self)",
                    actual: "\(type(of: value))",
                )
            }
            return value
        }

        private func getFromStorage<V>(valueFor distinctKey: DistinctKey) throws -> V? where V: Sendable {
            // Memory-only path
            if let memoryEntries = depot.memoryEntries {
                guard let entry = memoryEntries.withLock({ $0[distinctKey] }) else {
                    return nil
                }
                if let expiresAt = entry.expiresAt, depot.clock.now() >= expiresAt {
                    return nil
                }
                return try cast(entry.value, for: distinctKey)
            }

            // File-backed path
            let now = depot.clock.now()
            if let memoryCache = depot.memoryCache {
                switch memoryCache.lookup(valueFor: distinctKey, at: now) as DepotMemoryCache.CacheLookupResult<V> {
                case let .hit(value):
                    return value
                case .confirmedAbsent:
                    return nil
                case .expired:
                    memoryCache.markExpired(for: distinctKey)
                    return nil
                case .miss:
                    break
                }
            }

            let fileURL = distinctKey.getFileURL(from: depot.configuration.directoryURL!)

            let fileData: Data
            do {
                fileData = try Data(
                    contentsOf: fileURL,
                    options: depot.configuration.cacheInMemory ? .uncached : .mappedIfSafe,
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // Another process may remove the file between reads (app-group
                // depots) — treat it as absent, like the non-transactional path.
                depot.memoryCache?.set(value: nil as V?, for: distinctKey, expiresAt: nil)
                return nil
            }

            guard let (header, valueData) = try FileHeader.parseAndValidate(fileData, at: now) else {
                return nil
            }

            let value: V = try depot.core.coder(for: distinctKey.key, as: V.self).decode(valueData)

            depot.memoryCache?.set(
                value: value,
                for: distinctKey,
                cost: fileData.count,
                expiresAt: header?.expiresAt
            )

            return value
        }

        /// Reads all values in committed storage matching `key`, skipping keys
        /// that have a buffered mutation (the overlay supersedes them) and, when
        /// a full removal is pending, skipping storage entirely.
        ///
        /// Per-key failures are routed to `onError`, which may either rethrow
        /// (fail-fast) or collect the error (partial success).
        private func storageValues<V>(
            matching key: some TypedKeyProtocol<V>,
            onError: (DistinctKey, any Error & Sendable) throws -> Void,
        ) throws -> [DistinctKey: V] where V: Sendable {
            guard !pendingRemoveAll else {
                return [:]
            }

            var keyedValues = [DistinctKey: V]()

            // Memory-only path
            if let memoryEntries = depot.memoryEntries {
                let now = depot.clock.now()
                let matches = memoryEntries.withLock { entries in
                    entries.filter { key.matches($0.key) }
                }
                for (distinctKey, entry) in matches where pendingMutations[distinctKey] == nil {
                    if let expiresAt = entry.expiresAt, now >= expiresAt {
                        continue
                    }
                    do {
                        keyedValues[distinctKey] = try cast(entry.value, for: distinctKey) as V
                    } catch {
                        try onError(
                            distinctKey,
                            DepotError.mismatchedTypes(
                                keyPath: distinctKey.keyPath,
                                expected: "\(V.self)",
                                actual: "\(type(of: entry.value))",
                            )
                        )
                    }
                }
                return keyedValues
            }

            // File-backed path
            let now = depot.clock.now()
            let files = try depot.fileManager!.files(for: key)

            for (fileURL, fileKey) in files where pendingMutations[fileKey] == nil {
                if let memoryCache = depot.memoryCache {
                    switch memoryCache.lookup(valueFor: fileKey, at: now) as DepotMemoryCache.CacheLookupResult<V> {
                    case let .hit(value):
                        keyedValues[fileKey] = value
                        continue
                    case .confirmedAbsent:
                        continue
                    case .expired:
                        memoryCache.markExpired(for: fileKey)
                        continue
                    case .miss:
                        break
                    }
                }

                do {
                    let fileData = try Data(
                        contentsOf: fileURL,
                        options: depot.configuration.cacheInMemory ? .uncached : .mappedIfSafe,
                    )

                    guard let (header, valueData) = try FileHeader.parseAndValidate(fileData, at: now) else {
                        continue
                    }

                    let value = try depot.core.coder(for: fileKey.key, as: V.self).decode(valueData)
                    depot.memoryCache?.set(
                        value: value,
                        for: fileKey,
                        cost: fileData.count,
                        expiresAt: header?.expiresAt
                    )
                    keyedValues[fileKey] = value
                } catch {
                    try onError(fileKey, error)
                }
            }

            return keyedValues
        }

        /// Counts committed storage values matching `key`, skipping keys that
        /// are tombstoned or already counted as buffered writes.
        private func storageCount(
            for key: some KeyProtocol,
            tombstonedKeys: Set<DistinctKey>,
            bufferedWriteKeys: Set<DistinctKey>,
        ) throws -> Int {
            let excludedKeys = tombstonedKeys.union(bufferedWriteKeys)

            // Memory-only path
            if let memoryEntries = depot.memoryEntries {
                let now = depot.clock.now()
                return memoryEntries.withLock { entries in
                    entries.count { entryKey, entry in
                        guard key.matches(entryKey), !excludedKeys.contains(entryKey) else {
                            return false
                        }
                        if let expiresAt = entry.expiresAt, now >= expiresAt {
                            return false
                        }
                        return true
                    }
                }
            }

            // File-backed path
            let now = depot.clock.now()
            let files = try depot.fileManager!.files(for: key)
            var count = 0
            for (fileURL, fileKey) in files
            where !excludedKeys.contains(fileKey) && FileHeader.isNonExpired(at: fileURL, now: now) == true {
                count += 1
            }
            return count
        }

        /// Checks committed storage for a non-expired value matching `key`,
        /// skipping keys tombstoned in the buffer.
        ///
        /// The memory-cache fast path is only consulted when no tombstone can
        /// match — a cached "exists" answer cannot distinguish which concrete
        /// key it came from.
        private func storageHas(
            valuesFor key: some KeyProtocol,
            tombstonedKeys: Set<DistinctKey>,
        ) throws -> Bool {
            // Memory-only path
            if let memoryEntries = depot.memoryEntries {
                let now = depot.clock.now()
                return memoryEntries.withLock { entries in
                    entries.contains { entryKey, entry in
                        guard key.matches(entryKey), !tombstonedKeys.contains(entryKey) else {
                            return false
                        }
                        if let expiresAt = entry.expiresAt, now >= expiresAt {
                            return false
                        }
                        return true
                    }
                }
            }

            // File-backed path
            let now = depot.clock.now()

            if tombstonedKeys.isEmpty,
                let memoryCache = depot.memoryCache,
                let hasValue = memoryCache.has(valuesFor: key, at: now)
            {
                return hasValue
            }

            let files = try depot.fileManager!.files(for: key)
            for (fileURL, fileKey) in files
            where !tombstonedKeys.contains(fileKey) && FileHeader.isNonExpired(at: fileURL, now: now) == true {
                return true
            }
            return false
        }
    }

    struct TransactionOutcome<T> {
        let result: Result<T, any Error>
        let modifiedKeys: Set<DistinctKey>
        let removedKeys: Set<DistinctKey>
        let emptyPatternRemovals: [Key]
        let didRemoveAll: Bool

        static func rolledBack(_ error: any Error) -> Self {
            TransactionOutcome(
                result: .failure(error),
                modifiedKeys: [],
                removedKeys: [],
                emptyPatternRemovals: [],
                didRemoveAll: false,
            )
        }
    }

    /// Executes `work` as an atomic transaction against this depot.
    ///
    /// Mutations made inside `work` are buffered and applied to storage only
    /// after the closure returns successfully. If `work` throws, all buffered
    /// mutations are discarded, the depot remains unchanged, and no observers
    /// are notified. On commit, observers receive a single coalesced
    /// notification for all affected keys.
    ///
    /// ```swift
    /// try depot.transaction { transaction in
    ///     let count = try transaction.get(valueFor: counterKey) ?? 0
    ///     try transaction.set(value: count + 1, for: counterKey)
    /// }
    /// ```
    ///
    /// - Parameter work: A closure that receives an `inout` ``DepotTransaction``.
    /// - Returns: The return value of `work`.
    /// - Throws: Any error thrown by `work` (after rollback), or an I/O error
    ///   raised while committing the buffered mutations (see
    ///   ``DepotTransaction`` for the commit failure semantics).
    @discardableResult
    public func transaction<T>(
        _ work: (inout DepotTransaction) throws -> T,
    ) throws -> T {
        LOG(level: .debug, message: "Depot[\(label)] transaction begin")

        let outcome: TransactionOutcome<T> = lock.withWriteLock {
            var transaction = Transaction(depot: self)

            let value: T
            do {
                value = try withUnsafeMutablePointer(to: &transaction) { ptr in
                    var depotTransaction = DepotTransaction(box: DepotTransactionPointerBox(ptr))
                    return try work(&depotTransaction)
                }
            } catch {
                // Roll back: discard the buffer, storage was never touched.
                return .rolledBack(error)
            }

            do {
                // Commit: materialize the buffered mutations.
                try transaction.flush()
            } catch {
                // The flush may have applied part of the buffer before
                // failing. Report those keys so observers stay in sync with
                // what is now visible in storage.
                return TransactionOutcome(
                    result: .failure(error),
                    modifiedKeys: transaction.appliedModifiedKeys,
                    removedKeys: transaction.appliedRemovedKeys,
                    emptyPatternRemovals: [],
                    didRemoveAll: transaction.appliedRemoveAll,
                )
            }

            if transaction.needsPruneEmptyDirectories {
                try? fileManager?.pruneEmptyDirectories()
            }

            if transaction.needsTouchLock {
                do {
                    try fileManager?.touchLock()
                } catch {
                    LOG(
                        level: .error,
                        message:
                            "Depot[\(label)] failed to touch lock for multi process support due to error \(error)",
                    )
                }
            }

            return TransactionOutcome(
                result: .success(value),
                modifiedKeys: transaction.appliedModifiedKeys,
                removedKeys: transaction.appliedRemovedKeys,
                emptyPatternRemovals: transaction.emptyPatternRemovals,
                didRemoveAll: transaction.appliedRemoveAll,
            )
        }

        // Notify about everything that reached storage — all mutations on
        // commit, the applied subset on a partial flush failure, nothing on
        // rollback (all-empty outcome is a no-op).
        core.notifyTransactionObservers(
            modified: outcome.modifiedKeys,
            removed: outcome.removedKeys,
            emptyPatternRemovals: outcome.emptyPatternRemovals,
            didRemoveAll: outcome.didRemoveAll,
            in: self,
        )

        switch outcome.result {
        case let .success(value):
            LOG(
                level: .debug,
                message:
                    "Depot[\(label)] transaction committed (\(outcome.modifiedKeys.count) modified, \(outcome.removedKeys.count) removed)",
            )
            return value
        case let .failure(error):
            if outcome.didRemoveAll || !outcome.modifiedKeys.isEmpty || !outcome.removedKeys.isEmpty {
                LOG(
                    level: .error,
                    message:
                        "Depot[\(label)] transaction commit failed after partially applying "
                        + "\(outcome.modifiedKeys.count) writes and \(outcome.removedKeys.count) removals: \(error)",
                )
            } else {
                LOG(level: .error, message: "Depot[\(label)] transaction rolled back: \(error)")
            }
            throw error
        }
    }
}

// MARK: - Async Transaction

extension Depot {
    /// Asynchronously executes `work` within a transaction, using the depot's concurrency control.
    ///
    /// The transaction closure acquires a semaphore slot before executing.
    /// The closure must not suspend (`await`).
    ///
    /// ```swift
    /// let newBalance = try await depot.transaction { transaction in
    ///     let current: Int = try transaction.get(valueFor: balanceKey) ?? 0
    ///     let updated = current + 100
    ///     try transaction.set(value: updated, for: balanceKey)
    ///     return updated
    /// }
    /// ```
    ///
    /// If `work` throws, all mutations made inside the transaction are
    /// discarded — see ``Depot/transaction(_:)-swift.method`` for the full
    /// commit/rollback semantics.
    ///
    /// - Parameter work: A `@Sendable` closure that receives an `inout` transaction.
    ///   Must not suspend.
    /// - Returns: The return value of `work`.
    /// - Throws: Any error thrown by `work`.
    @discardableResult
    public func transaction<T>(
        _ work: @escaping @Sendable (inout DepotTransaction) throws -> T,
    ) async throws -> T where T: Sendable {
        try await withSemaphore {
            try self.transaction { transaction in
                try work(&transaction)
            }
        }
    }

}
