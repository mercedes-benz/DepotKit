// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// Tracks per-key modification dates for multi-process change detection.
///
/// Note: Only to be used by ``Depot``!
final class DepotChangeTracker: Sendable {
    private final class State: @unchecked Sendable {
        var modificationDates = [DistinctKey: Date]()
    }

    // MARK: Properties

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    // MARK: - Internal

    func modified(key: some DistinctKeyProtocol, at modificationDate: Date) {
        state.withLock { state in
            state.modificationDates[DistinctKey(key)] = modificationDate
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
        let oldModificationDates = state.withLock { state in
            let oldValue = state.modificationDates
            state.modificationDates = newModificationDates

            return oldValue
        }

        // Check for keys that have a later modification date
        let modifiedKeys = Set(newModificationDates.keys)
            .filter { key in
                guard let oldModificationDate = oldModificationDates[key],
                    let newModificationDate = newModificationDates[key]
                else {
                    return true  // added
                }

                return newModificationDate > oldModificationDate
            }

        // Keys that are in oldModificationDates but not in newModificationDates have been removed
        let removedKeys = Set(oldModificationDates.keys)
            .subtracting(newModificationDates.keys)

        return (modifiedKeys, removedKeys)
    }
}
