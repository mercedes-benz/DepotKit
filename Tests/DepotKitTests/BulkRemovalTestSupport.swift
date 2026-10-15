// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// The error thrown by injected file-system failures.
struct InjectedFailure: Error, Equatable {
    let id = UUID()
}

/// A ``Depot/TestHooks/willRemoveItem`` hook that lets the first `n - 1` removals of key files
/// succeed and fails the `n`-th one. Internal (`.FS_*`) items never count and never fail.
final class FailingRemovalHook: Sendable {
    let failure = InjectedFailure()
    private let failOnRemoval: Int
    private let removals = OSAllocatedUnfairLock(initialState: 0)

    init(failOnRemoval: Int) {
        self.failOnRemoval = failOnRemoval
    }

    /// The number of key-file removals attempted so far (including the failing one).
    var attempts: Int {
        removals.withLock { $0 }
    }

    func callAsFunction(_ url: URL) throws {
        guard !url.lastPathComponent.hasPrefix(Depot.HiddenKeyPrefix) else {
            return
        }
        let attempt = removals.withLock { count in
            count += 1
            return count
        }
        if attempt == failOnRemoval {
            throw failure
        }
    }
}

/// Collects every delivery of an observer in order.
final class DeliveryLog<Element: Sendable>: Sendable {
    private let deliveries = OSAllocatedUnfairLock<[Element]>(initialState: [])

    func append(_ element: Element) {
        deliveries.withLock { $0.append(element) }
    }

    var all: [Element] {
        deliveries.withLock { $0 }
    }

    var count: Int {
        deliveries.withLock { $0.count }
    }

    var last: Element? {
        deliveries.withLock { $0.last }
    }
}

extension DeliveryLog where Element == String? {
    /// The delivered value, or `"<error>"` for a failed delivery.
    static func value(of result: Result<String?, any Error>) -> String? {
        switch result {
        case let .success(value):
            value
        case .failure:
            "<error>"
        }
    }
}

enum BulkRemovalSupport {
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    }

    static func makeDepot(
        at url: URL,
        cache: DepotConfiguration.MemoryCacheCapacity = .default,
        multiProcess: Bool = true,
        hooks: Depot.TestHooks = Depot.TestHooks(),
    ) -> Depot {
        Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: multiProcess, memoryCache: cache),
            overrides: .init(initSweepDelay: .seconds(3600), testHooks: hooks),
        )
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// The pending tracker changes, ignoring the internal metadata key (tracked separately).
    static func pendingTrackerChanges(in depot: Depot) throws -> (modified: Set<DistinctKey>, removed: Set<DistinctKey>)
    {
        let tracker = try #require(depot.changeTracker)
        let snapshot = try #require(depot.fileManager).takeSnapshotOfModificationDates()
        let changes = tracker.setModificationDates(snapshot)
        let metadata = DistinctKey(depot.metadataKey)
        return (changes.modified.subtracting([metadata]), changes.removed.subtracting([metadata]))
    }

    /// Makes a directory read-only so files inside it cannot be deleted.
    static func setWritable(_ writable: Bool, directory: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o555],
            ofItemAtPath: directory.path(percentEncoded: false),
        )
    }

    static func lockFileModificationDate(in directory: URL) -> Date? {
        let lockURL = directory.appending(component: "\(Depot.HiddenKeyPrefix)LOCK")
        return try? lockURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Sets the lock file's modification date far in the past, so any later touch is observable.
    static func backdateLockFile(in directory: URL) throws {
        var lockURL = directory.appending(component: "\(Depot.HiddenKeyPrefix)LOCK")
        if !fileExists(lockURL) {
            FileManager.default.createFile(atPath: lockURL.path(percentEncoded: false), contents: nil)
        }
        var values = URLResourceValues()
        values.contentModificationDate = Date(timeIntervalSince1970: 1_000_000)
        try lockURL.setResourceValues(values)
    }
}
