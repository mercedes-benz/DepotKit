// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Regression tests: when a bulk deletion (reset, `removeAll()`, pattern removal) fails
/// part-way, the memory cache, the change tracker, and observers must be reconciled with the
/// mutations that did reach disk, and the original error must be rethrown.
///
/// The tests never assume a deletion order: they derive the applied subset from the files that
/// actually survived on disk and check every key against it.
@Suite("Bulk removal partial failures", .offCooperativePool)
struct BulkRemovalReconciliationTests {
    typealias Support = BulkRemovalSupport

    enum ResetOperation: String, CaseIterable, Sendable {
        case reset
        case removeAll
        case asyncReset
        case asyncRemoveAll

        func perform(on depot: Depot) async throws {
            switch self {
            case .reset, .removeAll:
                try performSynchronously(on: depot)
            case .asyncReset:
                try await depot.reset()
            case .asyncRemoveAll:
                try await depot.removeAll()
            }
        }

        private func performSynchronously(on depot: Depot) throws {
            if self == .reset {
                try depot.reset()
            } else {
                try depot.removeAll()
            }
        }
    }

    /// A depot populated with values, cached reads, and one observer per key.
    final class Fixture: Sendable {
        let url: URL
        let depot: Depot
        let keys: [TypedDistinctKey<String>]
        let values: [String]
        let logs: [DeliveryLog<String?>]
        let cancellables: [any DepotCancellable]

        init(url: URL, depot: Depot, keyPaths: [KeyPathExpression]) async throws {
            self.url = url
            self.depot = depot
            depot.register(key: Key.all, coder: .json(String.self))

            keys = keyPaths.map { Key.from($0, as: String.self) }
            values = keys.map { "value of \($0.keyPath)" }
            try Self.populate(depot, keys: keys, values: values)

            var logs = [DeliveryLog<String?>]()
            var cancellables = [any DepotCancellable]()
            for key in keys {
                let log = DeliveryLog<String?>()
                logs.append(log)
                cancellables.append(
                    depot.core.observe(
                        valueFor: key,
                        initialValue: true,
                        update: { log.append(DeliveryLog.value(of: $0)) },
                        in: depot,
                    ),
                )
            }
            self.logs = logs
            self.cancellables = cancellables

            await depot.waitForPendingObservations()
        }

        /// Writes every value and reads it back, so the memory cache holds all of them.
        private static func populate(_ depot: Depot, keys: [TypedDistinctKey<String>], values: [String]) throws {
            for (key, value) in zip(keys, values) {
                try depot.set(value: value, for: key)
            }
            for (key, value) in zip(keys, values) {
                #expect(try depot.get(valueFor: key) == value)
            }
        }

        func fileURL(_ index: Int) throws -> URL {
            try depot.fileURL(for: keys[index])
        }

        /// Checks that cached reads, cold reads, observers, and the change tracker all agree with the
        /// files that survived on disk. Returns the indices of removed and surviving keys.
        @discardableResult
        func expectConsistentWithDisk(
            checkTracker: Bool = true,
            sourceLocation: SourceLocation = #_sourceLocation,
        ) async throws -> (removed: [Int], survived: [Int]) {
            await depot.waitForPendingObservations()
            return try checkConsistencyWithDisk(checkTracker: checkTracker, sourceLocation: sourceLocation)
        }

        private func checkConsistencyWithDisk(
            checkTracker: Bool,
            sourceLocation: SourceLocation,
        ) throws -> (removed: [Int], survived: [Int]) {
            if checkTracker {
                // The tracker must not report the bulk operation's own deletions as external changes.
                let changes = try Support.pendingTrackerChanges(in: depot)
                #expect(changes.modified.isEmpty, "tracker reports modified keys", sourceLocation: sourceLocation)
                #expect(
                    changes.removed.isEmpty,
                    "tracker still tracks deleted keys: \(changes.removed)",
                    sourceLocation: sourceLocation,
                )
            }

            // Read-only, so that opening it does not recreate missing metadata.
            let cold = Depot(configuration: .init(directoryURL: url, readOnly: true, memoryCache: .disabled))
            cold.register(key: Key.all, coder: .json(String.self))

            var removed = [Int]()
            var survived = [Int]()
            for index in keys.indices {
                let onDisk = Support.fileExists(try fileURL(index))
                let expected = onDisk ? values[index] : nil
                if onDisk {
                    survived.append(index)
                } else {
                    removed.append(index)
                }

                let key = keys[index]
                #expect(
                    try depot.get(valueFor: key) == expected,
                    "cached read of \(key)",
                    sourceLocation: sourceLocation
                )
                #expect(try cold.get(valueFor: key) == expected, "cold read of \(key)", sourceLocation: sourceLocation)
                #expect(logs[index].last == expected, "observer of \(key)", sourceLocation: sourceLocation)
            }

            let pattern = Key.all.typed(as: String.self)
            #expect(
                Set(try depot.get(valuesFor: pattern)) == Set(survived.map { values[$0] }),
                "cached pattern read",
                sourceLocation: sourceLocation,
            )
            #expect(try depot.count(for: Key.all) == survived.count, sourceLocation: sourceLocation)
            return (removed, survived)
        }
    }

    private static var resetKeyPaths: [KeyPathExpression] {
        ["k0", "k1", "k2", "k3", "group" / "a", "group" / "b"]
    }

    // MARK: - Reset / removeAll

    @Test("reset failing after a deletion reconciles cache, tracker, and observers", arguments: ResetOperation.allCases)
    func resetFailingAfterDeletion(operation: ResetOperation) async throws {
        let url = Support.temporaryDirectory()
        let hook = FailingRemovalHook(failOnRemoval: 2)
        var hooks = Depot.TestHooks()
        hooks.willRemoveItem = { try hook($0) }
        let fixture = try await Fixture(
            url: url,
            depot: Support.makeDepot(at: url, hooks: hooks),
            keyPaths: Self.resetKeyPaths,
        )
        try Support.backdateLockFile(in: url)
        let backdated = try #require(Support.lockFileModificationDate(in: url))

        do {
            try await operation.perform(on: fixture.depot)
            Issue.record("expected the injected failure")
        } catch let error as InjectedFailure {
            #expect(error == hook.failure, "the original error is rethrown")
        }
        #expect(hook.attempts == 2)

        let (removed, survived) = try await fixture.expectConsistentWithDisk()
        #expect(!removed.isEmpty)
        #expect(!survived.isEmpty)

        // Something reached disk, so other processes are signaled.
        #expect((Support.lockFileModificationDate(in: url) ?? .distantPast) > backdated)
    }

    @Test("reset failing to recreate the metadata reconciles all deletions", arguments: ResetOperation.allCases)
    func resetFailingToRecreateMetadata(operation: ResetOperation) async throws {
        let url = Support.temporaryDirectory()
        let failure = InjectedFailure()
        let failMetadata = OSAllocatedUnfairLock(initialState: true)
        var hooks = Depot.TestHooks()
        hooks.willRecreateMetadata = {
            if failMetadata.withLock({ $0 }) {
                throw failure
            }
        }
        let fixture = try await Fixture(
            url: url,
            depot: Support.makeDepot(at: url, hooks: hooks),
            keyPaths: Self.resetKeyPaths,
        )
        try Support.backdateLockFile(in: url)
        let backdated = try #require(Support.lockFileModificationDate(in: url))

        do {
            try await operation.perform(on: fixture.depot)
            Issue.record("expected the injected failure")
        } catch let error as InjectedFailure {
            #expect(error == failure, "the original error is rethrown")
        }

        let (removed, survived) = try await fixture.expectConsistentWithDisk()
        #expect(removed.count == fixture.keys.count)
        #expect(survived.isEmpty)
        #expect((Support.lockFileModificationDate(in: url) ?? .distantPast) > backdated)

        // The store is empty, so verifying creates the missing metadata (the injected failure only affects recreation).
        try await fixture.depot.verifyIntegrity()
        failMetadata.withLock { $0 = false }
        try await fixture.depot.reset()
        try await fixture.depot.verifyIntegrity()
    }

    @Test("reset blocked by an undeletable subdirectory agrees with the surviving files")
    func resetWithUndeletableSubdirectory() async throws {
        let url = Support.temporaryDirectory()
        let fixture = try await Fixture(
            url: url,
            depot: Support.makeDepot(at: url),
            keyPaths: ["k0", "k1", "k2", "locked" / "a", "locked" / "b"],
        )
        let lockedDirectory = try fixture.fileURL(3).deletingLastPathComponent()
        try Support.setWritable(false, directory: lockedDirectory)
        defer {
            try? Support.setWritable(true, directory: lockedDirectory)
            try? FileManager.default.removeItem(at: url)
        }

        #expect(throws: (any Error).self) { try fixture.depot.reset() }

        let (removed, survived) = try await fixture.expectConsistentWithDisk()
        #expect(survived.contains(3) && survived.contains(4), "files in the undeletable directory survive")
        #expect(removed.count + survived.count == fixture.keys.count)
    }

    @Test("reset of a store that cannot be enumerated still reconciles conservatively")
    func resetWithUnreadableDirectory() async throws {
        let url = Support.temporaryDirectory()
        let fixture = try await Fixture(
            url: url,
            depot: Support.makeDepot(at: url),
            keyPaths: Self.resetKeyPaths,
        )
        // A directory with a decodable key-component name whose contents cannot be listed:
        // enumerating the depot fails, and so does deleting the directory.
        let unreadable = try fixture.depot.fileURL(for: Key.from("unreadable" / "x"))
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: unreadable.appending(component: "junk").path(), contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path())
        defer {
            try? Support.setWritable(true, directory: unreadable)
            try? FileManager.default.removeItem(at: url)
        }
        #expect(throws: (any Error).self) { try fixture.depot.files(forAllKeysIn: url) }

        #expect(throws: (any Error).self) { try fixture.depot.reset() }
        try Support.setWritable(true, directory: unreadable)

        // The tracker conservatively forgot every key, so it is not checked here.
        let (removed, survived) = try await fixture.expectConsistentWithDisk(checkTracker: false)
        #expect(removed.count + survived.count == fixture.keys.count)
    }

    // MARK: - Pattern removal

    private static var patternKeyPaths: [KeyPathExpression] {
        [
            "users" / "u0" / "name", "users" / "u1" / "name", "users" / "u2" / "name", "users" / "u3" / "name",
            "users" / "u0" / "age", "other",
        ]
    }

    private static let namePattern = Key.from("users" / .wildcard / "name")

    @Test("pattern removal failing after a deletion reconciles cache, tracker, and observers")
    func patternRemovalFailingAfterDeletion() async throws {
        let url = Support.temporaryDirectory()
        let hook = FailingRemovalHook(failOnRemoval: 2)
        var hooks = Depot.TestHooks()
        hooks.willRemoveItem = { try hook($0) }
        let fixture = try await Fixture(
            url: url,
            depot: Support.makeDepot(at: url, hooks: hooks),
            keyPaths: Self.patternKeyPaths,
        )
        let patternLog = DeliveryLog<Set<String>>()
        let cancellable = fixture.depot.core.observe(
            valuesFor: Self.namePattern.typed(as: String.self),
            initialValues: true,
            update: { patternLog.append(Set((try? $0.get()) ?? ["<error>"])) },
            in: fixture.depot,
        )
        defer { cancellable.cancel() }
        try Support.backdateLockFile(in: url)
        let backdated = try #require(Support.lockFileModificationDate(in: url))

        do {
            try await fixture.depot.remove(valuesFor: Self.namePattern)
            Issue.record("expected the injected failure")
        } catch let error as InjectedFailure {
            #expect(error == hook.failure, "the original error is rethrown")
        }
        #expect(hook.attempts == 2)

        let (removed, survived) = try await fixture.expectConsistentWithDisk()
        #expect(removed.count == 1)
        #expect(Set(survived).isSuperset(of: [4, 5]), "keys outside the pattern are untouched")
        #expect(patternLog.last == Set(survived.filter { $0 < 4 }.map { fixture.values[$0] }))
        #expect((Support.lockFileModificationDate(in: url) ?? .distantPast) > backdated)
    }

    @Test("pattern removal failing on the first deletion changes nothing and does not signal")
    func patternRemovalFailingImmediately() async throws {
        let url = Support.temporaryDirectory()
        let hook = FailingRemovalHook(failOnRemoval: 1)
        var hooks = Depot.TestHooks()
        hooks.willRemoveItem = { try hook($0) }
        let fixture = try await Fixture(
            url: url,
            depot: Support.makeDepot(at: url, hooks: hooks),
            keyPaths: Self.patternKeyPaths,
        )
        try Support.backdateLockFile(in: url)
        let backdated = try #require(Support.lockFileModificationDate(in: url))
        let deliveries = fixture.logs.map(\.count)

        #expect(throws: InjectedFailure.self) { try fixture.depot.remove(valuesFor: Self.namePattern) }

        let (removed, _) = try await fixture.expectConsistentWithDisk()
        #expect(removed.isEmpty)
        #expect(fixture.logs.map(\.count) == deliveries, "no observer is notified")
        #expect(Support.lockFileModificationDate(in: url) == backdated)
    }

    @Test("pattern removal blocked by an undeletable directory agrees with the surviving files")
    func patternRemovalWithUndeletableDirectory() async throws {
        let url = Support.temporaryDirectory()
        let fixture = try await Fixture(
            url: url,
            depot: Support.makeDepot(at: url),
            keyPaths: Self.patternKeyPaths,
        )
        let lockedDirectory = try fixture.fileURL(1).deletingLastPathComponent()
        try Support.setWritable(false, directory: lockedDirectory)
        defer {
            try? Support.setWritable(true, directory: lockedDirectory)
            try? FileManager.default.removeItem(at: url)
        }

        #expect(throws: (any Error).self) { try fixture.depot.remove(valuesFor: Self.namePattern) }

        let (_, survived) = try await fixture.expectConsistentWithDisk()
        #expect(Set(survived).isSuperset(of: [1, 4, 5]))
    }
}

extension Depot {
    /// Enumerates all key files (throws if the store cannot be enumerated).
    fileprivate func files(forAllKeysIn _: URL) throws -> [(fileURL: URL, key: DistinctKey)] {
        try fileManager!.files(for: Key.all)
    }
}
