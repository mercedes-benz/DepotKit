// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Regression tests: a transaction commit that fails after at least one mutation reached
/// disk must still signal other processes (touch the shared lock file), so peers pick up the
/// partially applied state. Fully rolled-back transactions must not signal.
///
/// Peers are modeled by a second depot instance on the same directory with multi-process support;
/// it participates in the same lock-file protocol as an app extension process.
@Suite("Partial transaction commits signal other processes", .offCooperativePool)
struct TransactionPartialCommitSignalingTests {
    typealias Support = BulkRemovalSupport

    /// A writer depot with injectable failures and a peer depot that cached every value.
    struct Fixture {
        let url: URL
        let writer: Depot
        let peer: Depot
        let keys: [TypedDistinctKey<String>]
        let backdatedLock: Date

        init(hooks: Depot.TestHooks) throws {
            url = Support.temporaryDirectory()
            writer = Support.makeDepot(at: url, hooks: hooks)
            peer = Support.makeDepot(at: url)
            writer.register(key: Key.all, coder: .json(String.self))
            peer.register(key: Key.all, coder: .json(String.self))

            keys = ["a", "b", "c"].map { Key.from("items" / $0, as: String.self) }
            for key in keys {
                try writer.set(value: key.keyPath, for: key)
            }

            // The peer knows (and caches) the committed state before the transaction.
            try peer.checkForExternalChanges()
            for key in keys {
                #expect(try peer.get(valueFor: key) == key.keyPath)
            }

            try Support.backdateLockFile(in: url)
            backdatedLock = try #require(Support.lockFileModificationDate(in: url))
        }

        var lockWasTouched: Bool {
            (Support.lockFileModificationDate(in: url) ?? .distantPast) > backdatedLock
        }

        /// After invalidation, the peer must agree with the files on disk.
        func expectPeerAgreesWithDisk(sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
            try peer.checkForExternalChanges()
            var removed = 0
            for key in keys {
                let onDisk = Support.fileExists(try writer.fileURL(for: key))
                if !onDisk {
                    removed += 1
                }
                let expected = onDisk ? key.keyPath : nil
                #expect(try peer.get(valueFor: key) == expected, "peer read of \(key)", sourceLocation: sourceLocation)
                #expect(
                    try writer.get(valueFor: key) == expected,
                    "writer read of \(key)",
                    sourceLocation: sourceLocation
                )
            }
            return removed
        }
    }

    @Test("a partial removal commit touches the lock file and peers pick up the applied subset")
    func partialRemovalSignals() throws {
        let hook = FailingRemovalHook(failOnRemoval: 2)
        var hooks = Depot.TestHooks()
        hooks.willRemoveItem = { try hook($0) }
        let fixture = try Fixture(hooks: hooks)

        do {
            try fixture.writer.transaction { transaction in
                try transaction.remove(valueFor: fixture.keys[0])
                try transaction.remove(valueFor: fixture.keys[1])
            }
            Issue.record("expected the injected failure")
        } catch let error as InjectedFailure {
            #expect(error == hook.failure, "the original flush error is rethrown")
        }
        #expect(hook.attempts == 2)

        #expect(fixture.lockWasTouched, "other processes must be signaled")
        #expect(try fixture.expectPeerAgreesWithDisk() == 1)
    }

    @Test("a partial pattern-removal commit signals")
    func partialPatternRemovalSignals() throws {
        let hook = FailingRemovalHook(failOnRemoval: 2)
        var hooks = Depot.TestHooks()
        hooks.willRemoveItem = { try hook($0) }
        let fixture = try Fixture(hooks: hooks)

        #expect(throws: InjectedFailure.self) {
            try fixture.writer.transaction { try $0.remove(valuesFor: Key.from("items" / .wildcard)) }
        }

        #expect(fixture.lockWasTouched)
        #expect(try fixture.expectPeerAgreesWithDisk() == 1)
    }

    @Test("a partial removeAll commit signals and reconciles the applied subset")
    func partialRemoveAllSignals() throws {
        let hook = FailingRemovalHook(failOnRemoval: 2)
        var hooks = Depot.TestHooks()
        hooks.willRemoveItem = { try hook($0) }
        let fixture = try Fixture(hooks: hooks)
        // Spread the keys over several top-level items so that one of them can be deleted first.
        let topLevel = ["x", "y"].map { Key.from(KeyPathExpression($0), as: String.self) }
        for key in topLevel {
            try fixture.writer.set(value: key.keyPath, for: key)
        }
        try fixture.peer.checkForExternalChanges()
        try Support.backdateLockFile(in: fixture.url)

        #expect(throws: InjectedFailure.self) {
            try fixture.writer.transaction { try $0.removeAll() }
        }

        #expect((Support.lockFileModificationDate(in: fixture.url) ?? .distantPast) > fixture.backdatedLock)
        _ = try fixture.expectPeerAgreesWithDisk()
        for key in topLevel {
            let expected = Support.fileExists(try fixture.writer.fileURL(for: key)) ? key.keyPath : nil
            #expect(try fixture.writer.get(valueFor: key) == expected)
            #expect(try fixture.peer.get(valueFor: key) == expected)
        }
    }

    @Test("a removeAll commit failing to recreate the metadata still commits and signals")
    func metadataRecreationFailureSignals() throws {
        let failure = InjectedFailure()
        var hooks = Depot.TestHooks()
        hooks.willRecreateMetadata = { throw failure }
        let fixture = try Fixture(hooks: hooks)

        try fixture.writer.transaction { try $0.removeAll() }

        #expect(fixture.lockWasTouched)
        #expect(try fixture.expectPeerAgreesWithDisk() == fixture.keys.count)
    }

    @Test("a commit with writes and a failing removal signals")
    func mixedPartialCommitSignals() throws {
        let hook = FailingRemovalHook(failOnRemoval: 2)
        var hooks = Depot.TestHooks()
        hooks.willRemoveItem = { try hook($0) }
        let fixture = try Fixture(hooks: hooks)
        let newKey = Key.from("items" / "new", as: String.self)

        #expect(throws: InjectedFailure.self) {
            try fixture.writer.transaction { transaction in
                try transaction.set(value: "new", for: newKey)
                try transaction.remove(valueFor: fixture.keys[0])
                try transaction.remove(valueFor: fixture.keys[1])
            }
        }

        #expect(fixture.lockWasTouched)
        #expect(try fixture.expectPeerAgreesWithDisk() == 1)
        let newExpected = Support.fileExists(try fixture.writer.fileURL(for: newKey)) ? "new" : nil
        #expect(try fixture.peer.get(valueFor: newKey) == newExpected)
    }

    @Test("a commit failing before any mutation reached disk does not signal")
    func failedCommitWithoutAppliedMutationsDoesNotSignal() throws {
        let hook = FailingRemovalHook(failOnRemoval: 1)
        var hooks = Depot.TestHooks()
        hooks.willRemoveItem = { try hook($0) }
        let fixture = try Fixture(hooks: hooks)

        #expect(throws: InjectedFailure.self) {
            try fixture.writer.transaction { try $0.remove(valueFor: fixture.keys[0]) }
        }

        #expect(!fixture.lockWasTouched)
        #expect(try fixture.expectPeerAgreesWithDisk() == 0)
    }

    @Test("a rolled-back transaction does not signal")
    func rolledBackTransactionDoesNotSignal() throws {
        let fixture = try Fixture(hooks: Depot.TestHooks())
        struct Abort: Error {}

        #expect(throws: Abort.self) {
            try fixture.writer.transaction { transaction in
                try transaction.remove(valueFor: fixture.keys[0])
                try transaction.set(value: "changed", for: fixture.keys[1])
                throw Abort()
            }
        }

        #expect(!fixture.lockWasTouched)
        #expect(try fixture.expectPeerAgreesWithDisk() == 0)
    }

    @Test("a successful commit signals")
    func successfulCommitSignals() throws {
        let fixture = try Fixture(hooks: Depot.TestHooks())

        try fixture.writer.transaction { try $0.remove(valueFor: fixture.keys[0]) }

        #expect(fixture.lockWasTouched)
        #expect(try fixture.expectPeerAgreesWithDisk() == 1)
    }
}
