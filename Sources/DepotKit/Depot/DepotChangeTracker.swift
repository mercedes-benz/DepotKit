// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// Tracks per-key modification dates for multi-process change detection.
///
/// A key counts as modified when its on-disk modification date differs from the
/// recorded one (earlier or later). Content that is replaced while deliberately
/// preserving the previous modification date is not detected.
///
/// Keys of internal files (such as the depot metadata) are never tracked: snapshots
/// exclude those files, so tracking them would report them as removed.
///
/// Note: Only to be used by ``Depot``!
final class DepotChangeTracker: Sendable {
    private final class State: @unchecked Sendable {
        var modificationDates = [DistinctKey: Date]()
    }

    // MARK: Properties

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let ignoredKeys: Set<DistinctKey>

    // MARK: - Init

    init(ignoredKeys: Set<DistinctKey> = []) {
        self.ignoredKeys = ignoredKeys
    }

    // MARK: - Internal

    func modified(key: some DistinctKeyProtocol, at modificationDate: Date) {
        let distinctKey = DistinctKey(key)
        guard !ignoredKeys.contains(distinctKey) else {
            return
        }
        state.withLock { state in
            state.modificationDates[distinctKey] = modificationDate
        }
    }

    func removed(key: some KeyProtocol) {
        state.withLock { state in
            guard key.components != [.globstar] else {
                state.modificationDates.removeAll()
                return
            }

            let keys = state.modificationDates.keys
                .filter { key.matches($0.key) }

            for key in keys {
                state.modificationDates[key] = nil
            }
        }
    }

    @discardableResult
    func setModificationDates(
        _ newModificationDates: [DistinctKey: Date],
    ) -> (
        modified: Set<DistinctKey>, removed: Set<DistinctKey>
    ) {
        let newModificationDates =
            ignoredKeys.isEmpty ? newModificationDates : newModificationDates.filter { !ignoredKeys.contains($0.key) }

        let oldModificationDates = state.withLock { state in
            let oldValue = state.modificationDates
            state.modificationDates = newModificationDates

            return oldValue
        }

        // Any differing modification date is a change: restores, preserved older timestamps,
        // and wall-clock rollbacks can produce dates that are earlier than the recorded ones.
        let modifiedKeys = Set(newModificationDates.keys)
            .filter { key in
                guard let oldModificationDate = oldModificationDates[key],
                    let newModificationDate = newModificationDates[key]
                else {
                    return true  // added
                }

                return newModificationDate != oldModificationDate
            }

        // Keys that are in oldModificationDates but not in newModificationDates have been removed
        let removedKeys = Set(oldModificationDates.keys)
            .subtracting(newModificationDates.keys)

        return (modifiedKeys, removedKeys)
    }
}
