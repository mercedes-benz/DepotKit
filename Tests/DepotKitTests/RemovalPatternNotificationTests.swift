// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Regression tests: removing a pattern must notify every observer whose key matches a
/// removed value — including observers whose pattern merely intersects the removal pattern — and
/// must not notify anyone when nothing was removed.
@Suite("Removal notifications for intersecting patterns")
struct RemovalPatternNotificationTests {
    enum StorageMode: String, CaseIterable, Sendable {
        case memory
        case file
        case fileCached

        func makeDepot() -> Depot {
            switch self {
            case .memory:
                Depot()
            case .file:
                Depot.temporary(memoryCache: .disabled)
            case .fileCached:
                Depot.temporary(memoryCache: .default)
            }
        }
    }

    /// A depot holding `users/{alice,bob}/{name,age}` and `teams/core/name`.
    struct Fixture {
        let depot: Depot

        static let users = ["alice", "bob"]
        static let fields = ["name", "age"]

        init(mode: StorageMode) throws {
            depot = mode.makeDepot()
            depot.register(key: Key.all, coder: .json(String.self))
            for user in Self.users {
                for field in Self.fields {
                    try depot.set(value: "\(user).\(field)", for: Self.key(user, field))
                }
            }
            try depot.set(value: "core.name", for: Key.from("teams" / "core" / "name", as: String.self))
        }

        static func key(_ user: String, _ field: String) -> TypedDistinctKey<String> {
            Key.from("users" / user / field, as: String.self)
        }

        /// Observes `pattern` and records every delivered snapshot as a set.
        func observe(_ pattern: Key) -> (DeliveryLog<Set<String>>, any DepotCancellable) {
            let log = DeliveryLog<Set<String>>()
            let cancellable = depot.core.observe(
                valuesFor: pattern.typed(as: String.self),
                initialValues: true,
                update: { log.append(Set((try? $0.get()) ?? ["<error>"])) },
                in: depot,
            )
            return (log, cancellable)
        }

        func observe(_ key: TypedDistinctKey<String>) -> (DeliveryLog<String?>, any DepotCancellable) {
            let log = DeliveryLog<String?>()
            let cancellable = depot.core.observe(
                valueFor: key,
                initialValue: true,
                update: { log.append(DeliveryLog.value(of: $0)) },
                in: depot,
            )
            return (log, cancellable)
        }

        func stored(_ pattern: Key) throws -> Set<String> {
            Set(try depot.get(valuesFor: pattern.typed(as: String.self)))
        }
    }

    struct Crossing: Sendable, CustomTestStringConvertible {
        let observed: Key
        let removed: Key

        var testDescription: String {
            "observe \(observed.keyPath), remove \(removed.keyPath)"
        }
    }

    static let crossings: [Crossing] = [
        Crossing(observed: Key.from("users" / .wildcard / "name"), removed: Key.from("users" / "alice" / .wildcard)),
        Crossing(observed: Key.from("users" / .wildcard / "name"), removed: Key.from(.wildcard / "alice" / .globstar)),
        Crossing(observed: Key.from(.globstar / "name"), removed: Key.from("users" / "alice" / .wildcard)),
        Crossing(observed: Key.from("users" / .globstar), removed: Key.from(.wildcard / "alice" / "name")),
        Crossing(observed: Key.from(.globstar / "alice" / .wildcard), removed: Key.from("users" / .wildcard / "name")),
    ]

    @Test(
        "observers of an intersecting pattern receive exactly one updated snapshot",
        arguments: StorageMode.allCases,
        crossings
    )
    func intersectingPatternRemovalNotifies(mode: StorageMode, crossing: Crossing) async throws {
        let fixture = try Fixture(mode: mode)
        let (log, cancellable) = fixture.observe(crossing.observed)
        defer { cancellable.cancel() }
        await fixture.depot.waitForPendingObservations()
        let before = log.count
        let initial = try fixture.stored(crossing.observed)
        #expect(log.last == initial)

        try await fixture.depot.remove(valuesFor: crossing.removed)
        await fixture.depot.waitForPendingObservations()

        let remaining = try fixture.stored(crossing.observed)
        #expect(remaining != initial, "the removal must affect the observed values")
        #expect(log.count == before + 1, "exactly one notification for one logical removal")
        #expect(log.last == remaining)
    }

    @Test("distinct observers are notified only for removed keys", arguments: StorageMode.allCases)
    func distinctObservers(mode: StorageMode) async throws {
        let fixture = try Fixture(mode: mode)
        let (aliceName, c1) = fixture.observe(Fixture.key("alice", "name"))
        let (aliceAge, c2) = fixture.observe(Fixture.key("alice", "age"))
        let (bobName, c3) = fixture.observe(Fixture.key("bob", "name"))
        defer {
            for cancellable in [c1, c2, c3] {
                cancellable.cancel()
            }
        }
        await fixture.depot.waitForPendingObservations()
        let counts = [aliceName.count, aliceAge.count, bobName.count]

        try await fixture.depot.remove(valuesFor: Key.from(.wildcard / "alice" / .globstar))
        await fixture.depot.waitForPendingObservations()

        #expect(aliceName.count == counts[0] + 1)
        #expect(aliceName.last == .some(nil))
        #expect(aliceAge.count == counts[1] + 1)
        #expect(aliceAge.last == .some(nil))
        #expect(bobName.count == counts[2], "bob's values were not removed")
    }

    @Test("pattern removals that remove nothing do not notify", arguments: StorageMode.allCases)
    func emptyRemovalsDoNotNotify(mode: StorageMode) async throws {
        let fixture = try Fixture(mode: mode)
        let observed = Key.from("users" / .wildcard / "name")
        let (log, cancellable) = fixture.observe(observed)
        let (aliceName, c2) = fixture.observe(Fixture.key("alice", "name"))
        defer {
            cancellable.cancel()
            c2.cancel()
        }

        // Remove the observed values once; this must notify.
        try await fixture.depot.remove(valuesFor: observed)
        await fixture.depot.waitForPendingObservations()
        #expect(log.last == [])
        #expect(aliceName.last == .some(nil))
        let counts = (log.count, aliceName.count)

        // Removing them again (and removing unrelated or missing patterns) removes nothing.
        try await fixture.depot.remove(valuesFor: observed)
        try await fixture.depot.remove(valuesFor: Key.from("users" / "carol" / .wildcard))
        try await fixture.depot.remove(valuesFor: Key.from(.globstar / "nickname"))
        await fixture.depot.waitForPendingObservations()

        #expect(log.count == counts.0)
        #expect(aliceName.count == counts.1)
        #expect(try fixture.stored(Key.from("users" / .wildcard / "age")) == ["alice.age", "bob.age"])
    }

    @Test("removing values outside an observed pattern does not notify it", arguments: StorageMode.allCases)
    func disjointRemovalDoesNotNotify(mode: StorageMode) async throws {
        let fixture = try Fixture(mode: mode)
        let (log, cancellable) = fixture.observe(Key.from("users" / .wildcard / "name"))
        defer { cancellable.cancel() }
        await fixture.depot.waitForPendingObservations()
        let before = log.count

        try await fixture.depot.remove(valuesFor: Key.from("users" / .wildcard / "age"))
        try await fixture.depot.remove(valuesFor: Key.from("teams" / .globstar))
        await fixture.depot.waitForPendingObservations()

        #expect(log.count == before)
    }

    @Test("transactional removals follow the same notification semantics", arguments: StorageMode.allCases)
    func transactionParity(mode: StorageMode) async throws {
        let fixture = try Fixture(mode: mode)
        let observed = Key.from("users" / .wildcard / "name")
        let (log, cancellable) = fixture.observe(observed)
        defer { cancellable.cancel() }
        await fixture.depot.waitForPendingObservations()
        var count = log.count

        try await fixture.depot.transaction { try $0.remove(valuesFor: Key.from("users" / "alice" / .wildcard)) }
        await fixture.depot.waitForPendingObservations()
        #expect(log.count == count + 1)
        #expect(log.last == ["bob.name"])
        count = log.count

        try await fixture.depot.transaction { try $0.remove(valuesFor: observed) }
        await fixture.depot.waitForPendingObservations()
        #expect(log.count == count + 1)
        #expect(log.last == [])
        count = log.count

        // A transactional pattern removal that matches nothing does not notify either.
        try await fixture.depot.transaction { try $0.remove(valuesFor: observed) }
        await fixture.depot.waitForPendingObservations()
        #expect(log.count == count)
    }
}

@Suite("Key pattern intersection")
struct KeyIntersectionTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let lhs: Key
        let rhs: Key
        let intersects: Bool

        var testDescription: String {
            "\(lhs.keyPath) ∩ \(rhs.keyPath) = \(intersects)"
        }
    }

    static let cases: [Case] = [
        Case(
            lhs: Key.from("users" / .wildcard / "name"),
            rhs: Key.from("users" / "alice" / .wildcard),
            intersects: true
        ),
        Case(
            lhs: Key.from("users" / .wildcard / "name"),
            rhs: Key.from(.wildcard / "alice" / .globstar),
            intersects: true
        ),
        Case(lhs: Key.from(.globstar / "name"), rhs: Key.from("users" / .globstar), intersects: true),
        Case(lhs: Key.from(.globstar / "name"), rhs: Key(Key.from("name")), intersects: true),
        Case(lhs: Key.from("a" / .globstar / "b"), rhs: Key.from(.globstar / "c" / .globstar), intersects: true),
        Case(lhs: Key.from("a" / .globstar), rhs: Key.from(.globstar / "b"), intersects: true),
        Case(lhs: Key.all, rhs: Key.from("users" / .wildcard / "name"), intersects: true),
        Case(
            lhs: Key(Key.from("users" / "alice" / "name")),
            rhs: Key.from("users" / .wildcard / "name"),
            intersects: true
        ),
        Case(
            lhs: Key.from("users" / .wildcard / "name"),
            rhs: Key.from("users" / .wildcard / "age"),
            intersects: false
        ),
        Case(lhs: Key.from("users" / .wildcard / "name"), rhs: Key.from("users" / .wildcard), intersects: false),
        Case(lhs: Key.from("users" / .wildcard), rhs: Key.from("teams" / .globstar), intersects: false),
        Case(lhs: Key.from(.wildcard / "name"), rhs: Key.from(.globstar / "a" / "b" / "name"), intersects: false),
        Case(lhs: Key.from("a" / .globstar / "b"), rhs: Key(Key.from("a")), intersects: false),
        Case(lhs: Key(Key.from("users" / "alice")), rhs: Key(Key.from("users" / "bob")), intersects: false),
    ]

    @Test("crossing patterns intersect symmetrically", arguments: cases)
    func intersection(testCase: Case) {
        #expect(DepotCore.keysIntersect(testCase.lhs, testCase.rhs) == testCase.intersects)
        #expect(DepotCore.keysIntersect(testCase.rhs, testCase.lhs) == testCase.intersects)
    }

    @Test("pattern removal notifications reach observers of intersecting patterns")
    func patternNotificationUsesIntersection() async throws {
        let depot = Depot()
        depot.register(key: Key.all, coder: .json(String.self))
        let log = DeliveryLog<[String]>()
        let cancellable = depot.core.observe(
            valuesFor: Key.from("users" / .wildcard / "name", as: String.self),
            initialValues: false,
            update: { log.append((try? $0.get()) ?? []) },
            in: depot,
        )
        defer { cancellable.cancel() }

        depot.core.notifyObservers(removed: Key.from("users" / "alice" / .wildcard), in: depot)
        depot.core.notifyObservers(removed: Key.from("users" / .wildcard / "age"), in: depot)
        await depot.waitForPendingObservations()

        #expect(log.count == 1)
    }
}
