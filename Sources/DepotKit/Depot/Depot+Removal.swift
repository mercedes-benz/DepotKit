// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

// MARK: - File Removal Bookkeeping

extension Depot {
    /// The part of a file-backed removal that reached disk.
    ///
    /// Bulk removals delete one item at a time, so a failure can leave them
    /// partially applied. The outcome records exactly what was deleted —
    /// even when ``error`` is set — so the memory cache, the change tracker,
    /// and observers can be reconciled with the surviving files.
    struct FileRemovalOutcome {
        /// Keys whose files are known to be gone.
        var removedKeys = Set<DistinctKey>()

        /// Whether the whole depot directory was cleared.
        var removedAll = false

        /// Whether an unknown subset of all values was removed (the files could
        /// not be enumerated before a failed bulk deletion). Treated like
        /// ``removedAll`` for reconciliation: observers re-read the surviving state.
        var removedUnknownSubset = false

        /// The first error that stopped the removal, if any.
        var error: (any Error)?

        /// Whether anything was deleted from disk.
        var didChangeStorage: Bool {
            removedAll || removedUnknownSubset || !removedKeys.isEmpty
        }

        /// Whether every observer must be notified, because all values (or an unknown subset) were removed.
        var affectsAllKeys: Bool {
            removedAll || removedUnknownSubset
        }
    }

    /// Deletes the files of all keys matching `key`, stopping at the first failure.
    ///
    /// Must be called while holding the write lock, inside the shared
    /// lock-file critical section. Empty directories are pruned afterwards.
    func removeFiles(matching key: some KeyProtocol) -> FileRemovalOutcome {
        var outcome = FileRemovalOutcome()

        do {
            for (fileURL, fileKey) in try fileManager!.files(for: key) {
                try testHooks.willRemoveItem?(fileURL)
                try fileManager!.removeItem(at: fileURL)
                outcome.removedKeys.insert(fileKey)
            }
        } catch {
            outcome.error = error
        }

        if outcome.didChangeStorage {
            pruneEmptyDirectories()
        }

        return outcome
    }

    /// Deletes every item in the depot directory, including the metadata file,
    /// but keeps the shared lock file.
    ///
    /// On failure, the keys whose files no longer exist are reported, so the
    /// applied subset is known regardless of the deletion order.
    ///
    /// Must be called while holding the write lock, inside the shared
    /// lock-file critical section.
    func removeAllFiles() -> FileRemovalOutcome {
        var outcome = FileRemovalOutcome()

        // Best effort: a store that cannot be fully enumerated must still be resettable.
        let existingFiles = try? fileManager!.files(for: Key.all)

        do {
            try fileManager!.removeDepotContents(willRemove: testHooks.willRemoveItem)
            outcome.removedAll = true
        } catch {
            outcome.error = error
            guard let existingFiles else {
                outcome.removedUnknownSubset = true
                return outcome
            }
            for (fileURL, key) in existingFiles where !fileManager!.hasFile(at: fileURL, skipHiddenFiles: false) {
                outcome.removedKeys.insert(key)
            }
        }

        return outcome
    }

    /// Updates the change tracker and the memory cache for deleted files.
    ///
    /// Call right after the deletion, before anything else is written.
    func reconcile(_ outcome: FileRemovalOutcome) {
        if outcome.affectsAllKeys {
            changeTracker?.removed(key: Key.all)
            memoryCache?.removeAll()
            return
        }

        guard !outcome.removedKeys.isEmpty else {
            return
        }

        for key in outcome.removedKeys {
            changeTracker?.removed(key: key)
        }
        memoryCache?.applyBatch(writes: [], removals: Array(outcome.removedKeys))
    }

    /// Recreates the metadata file after the depot directory was cleared.
    ///
    /// On failure the creation stays pending and is retried by later writes and `verifyIntegrity()`.
    func recreateMetadata() throws {
        do {
            try testHooks.willRecreateMetadata?()
            try checkMetadata(createIfNeeded: true)
        } catch {
            metadataCreationPending.withLock { $0 = true }
            throw error
        }
    }

    /// Removes empty directories left behind by deletions.
    ///
    /// Must run inside the shared lock-file critical section, so it cannot
    /// remove a directory that another depot instance or process is writing into.
    func pruneEmptyDirectories() {
        do {
            try fileManager?.pruneEmptyDirectories()
        } catch {
            LOG(level: .error, message: "Depot[\(label)] failed to prune empty directories: \(error)")
        }
    }
}
