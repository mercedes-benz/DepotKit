// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// The re-entrancy guard of the depot lock must not consume a per-instance, process-wide resource:
/// a process may keep any number of depots alive. It must still reject re-acquiring the same lock on
/// the same thread while allowing a thread that holds one depot's lock to use another depot.
@Suite("Lock re-entrancy guard")
struct LockReentrancyGuardTests {
    /// Well above the per-process limit of thread-specific data keys (512 on Darwin).
    static let depotCount = 2_000

    @Test("thousands of depots can be alive and used at the same time")
    func manyLiveDepots() throws {
        var depots: [Depot] = []
        depots.reserveCapacity(Self.depotCount)
        for _ in 0..<Self.depotCount {
            depots.append(Depot())
        }

        for (index, depot) in depots.enumerated() {
            let key = depot.register(keyPath: "value", coder: .json(Int.self))
            try depot.set(value: index, for: key)
            #expect(try depot.get(valueFor: key) == index)
        }
    }

    @Test("thousands of locks can be alive and used at the same time")
    func manyLiveLocks() {
        let locks = (0..<Self.depotCount).map { _ in ReadWriteLock() }
        var sum = 0
        for (index, lock) in locks.enumerated() {
            sum += lock.withWriteLock { index } + lock.withReadLock { 1 }
        }
        #expect(sum == (0..<Self.depotCount).reduce(0, +) + Self.depotCount)
    }

    @Test("a thread holding one lock can acquire other locks, then each lock again")
    func nestedDifferentLocks() throws {
        let first = ReadWriteLock()
        let second = ReadWriteLock()
        let third = ReadWriteLock()

        let result = first.withWriteLock {
            second.withReadLock {
                third.withWriteLock { 1 } + 1
            } + 1
        }
        #expect(result == 3)

        #expect(throws: GuardTestError.self) {
            try first.withReadLock {
                try second.withWriteLock { throw GuardTestError.intentional }
            }
        }

        // Every lock is released and no longer recorded as held by this thread.
        #expect(first.withWriteLock { true })
        #expect(second.withWriteLock { true })
        #expect(third.withReadLock { true })
    }

    @Test("a transaction on one depot can use another depot")
    func transactionUsesAnotherDepot() throws {
        let outer = Depot()
        let inner = Depot()
        let outerKey = outer.register(keyPath: "outer", coder: .json(Int.self))
        let innerKey = inner.register(keyPath: "inner", coder: .json(Int.self))

        try outer.transaction { transaction in
            try inner.set(value: 1, for: innerKey)
            let value = try inner.get(valueFor: innerKey) ?? 0
            try transaction.set(value: value + 1, for: outerKey)
        }

        #expect(try outer.get(valueFor: outerKey) == 2)
        #expect(try inner.get(valueFor: innerKey) == 1)
    }

    #if os(macOS)
    static let reentrancyMessage = "re-entrant lock acquisition detected"

    @Test("re-acquiring the same lock for reading inside a read lock traps")
    func readInsideRead() async throws {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let lock = ReadWriteLock()
            lock.withReadLock { lock.withReadLock {} }
        }
        #expect(result.map { Self.standardError(of: $0).contains(Self.reentrancyMessage) } == true)
    }

    @Test("re-acquiring the same lock for writing inside a write lock traps")
    func writeInsideWrite() async throws {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let lock = ReadWriteLock()
            lock.withWriteLock { lock.withWriteLock {} }
        }
        #expect(result.map { Self.standardError(of: $0).contains(Self.reentrancyMessage) } == true)
    }

    @Test("re-acquiring a lock held further out on the same thread traps")
    func reacquireOuterLockInsideAnotherLock() async throws {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let outer = ReadWriteLock()
            let inner = ReadWriteLock()
            outer.withWriteLock { inner.withReadLock { outer.withReadLock {} } }
        }
        #expect(result.map { Self.standardError(of: $0).contains(Self.reentrancyMessage) } == true)
    }

    @Test("calling the depot directly inside its own transaction traps")
    func depotCallInsideOwnTransaction() async throws {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let depot = Depot()
            let key = depot.register(keyPath: "value", coder: .json(Int.self))
            try? depot.transaction { _ in
                _ = try depot.get(valueFor: key)
            }
        }
        #expect(result.map { Self.standardError(of: $0).contains(Self.reentrancyMessage) } == true)
    }

    private static func standardError(of result: ExitTest.Result) -> String {
        String(decoding: result.standardErrorContent, as: UTF8.self)
    }
    #endif
}

private enum GuardTestError: Error {
    case intentional
}
