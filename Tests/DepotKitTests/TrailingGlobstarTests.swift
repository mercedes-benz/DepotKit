// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// A trailing globstar matches one or more components (like `dir/**` in gitignore), so a
/// value stored at the prefix itself — often of a different type — is not part of the family.
@Suite("Trailing globstar semantics")
struct TrailingGlobstarTests {
    enum Mode: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case memoryOnly
        case fileBacked
        case fileBackedCached

        var testDescription: String {
            rawValue
        }

        func makeDepot() -> Depot {
            switch self {
            case .memoryOnly:
                Depot()
            case .fileBacked:
                Depot.temporary()
            case .fileBackedCached:
                Depot.temporary(memoryCache: .default)
            }
        }
    }

    /// `users` holds a `[String]` list; `users/*` and `users/**` hold `Int` values.
    struct Fixture {
        let depot: Depot
        let list = Key.from("users", as: [String].self)
        let deep = Key.from("users" / .globstar, as: Int.self)
        let shallow = Key.from("users" / .wildcard, as: Int.self)

        static let storedList = ["alice", "bob"]

        init(mode: Mode) throws {
            depot = mode.makeDepot()
            depot.register(key: list, coder: .json([String].self))
            depot.register(key: shallow, coder: .json(Int.self))
            depot.register(key: deep, coder: .json(Int.self))

            try depot.set(value: Self.storedList, for: list)
            try depot.set(value: 1, for: Self.user("alice"))
            try depot.set(value: 2, for: Self.user("bob"))
            try depot.set(value: 3, for: Key.from("users" / "bob" / "age", as: Int.self))
        }

        static func user(_ name: String) -> TypedDistinctKey<Int> {
            Key.from("users" / name, as: Int.self)
        }

        static let deepKeyPaths: Set<String> = ["users/alice", "users/bob", "users/bob/age"]
    }

    // MARK: - Matching

    @Test("a trailing globstar matches one or more components")
    func trailingGlobstarMatching() {
        let users = Key.from("users" / .globstar)
        #expect(!users.matches(Key.from("users")))
        #expect(users.matches(Key.from("users" / "a")))
        #expect(users.matches(Key.from("users" / "a" / "b")))

        let perUser = Key.from("users" / .wildcard / .globstar)
        #expect(!perUser.matches(Key.from("users" / "a")))
        #expect(perUser.matches(Key.from("users" / "a" / "b")))

        let nested = Key.from(.globstar / "x" / .globstar)
        #expect(!nested.matches(Key.from("x")))
        #expect(!nested.matches(Key.from("a" / "x")))
        #expect(nested.matches(Key.from("x" / "y")))
        #expect(nested.matches(Key.from("a" / "x" / "y")))
    }

    @Test("leading and middle globstars still match zero or more components")
    func leadingAndMiddleGlobstarMatching() {
        let leading = Key.from(.globstar / "x")
        #expect(leading.matches(Key.from("x")))
        #expect(leading.matches(Key.from("a" / "x")))

        let middle = Key.from("a" / .globstar / "b")
        #expect(middle.matches(Key.from("a" / "b")))
        #expect(middle.matches(Key.from("a" / "c" / "b")))

        #expect(Key.all.matches(Key.from("a")))
        #expect(Key.all.matches(Key.from("a" / "b")))
    }

    @Test("pattern intersection follows the trailing globstar rule")
    func intersection() {
        let cases: [(Key, Key, Bool)] = [
            (Key.from("users" / .globstar), Key(Key.from("users")), false),
            (Key.from("users" / .globstar), Key(Key.from("users" / "a")), true),
            (Key.from("users" / .globstar), Key.from("users" / .wildcard), true),
            (Key.from("users" / .globstar), Key.from(PatternKeyPathExpression(.wildcard)), false),
            (Key.from("users" / .wildcard / .globstar), Key.from("users" / .wildcard), false),
            (Key.from(.globstar / "x" / .globstar), Key(Key.from("a" / "x")), false),
            (Key.from(.globstar / "x" / .globstar), Key.from(.globstar / "x"), true),
            (Key.from(.globstar / "x" / .globstar), Key.from(.globstar / "y"), true),
            (Key.from("a" / .globstar), Key.from(.globstar / "b"), true),
            (Key.all, Key(Key.from("users")), true),
        ]
        for (lhs, rhs, expected) in cases {
            #expect(DepotCore.keysIntersect(lhs, rhs) == expected, "\(lhs.keyPath) ∩ \(rhs.keyPath)")
            #expect(DepotCore.keysIntersect(rhs, lhs) == expected, "\(rhs.keyPath) ∩ \(lhs.keyPath)")
        }
    }

    // MARK: - Depot Operations

    @Test("pattern reads skip the differently typed prefix value", arguments: Mode.allCases)
    func reads(mode: Mode) throws {
        let fixture = try Fixture(mode: mode)
        let depot = fixture.depot

        #expect(try depot.get(valuesFor: fixture.deep).sorted() == [1, 2, 3])
        #expect(try depot.get(valuesFor: fixture.shallow).sorted() == [1, 2])

        let available = try depot.get(availableValuesFor: fixture.deep)
        #expect(Set(available.keyedValues.keys.map(\.keyPath)) == Fixture.deepKeyPaths)
        #expect(available.keyedErrors.isEmpty)

        #expect(try depot.count(for: fixture.deep) == 3)
        #expect(try depot.count(for: fixture.shallow) == 2)
        #expect(try depot.has(valuesFor: fixture.deep))
        #expect(try depot.get(valueFor: fixture.list) == Fixture.storedList)

        let inTransaction = try depot.transaction { tx in
            (try tx.get(valuesFor: fixture.deep).sorted(), try tx.count(for: fixture.deep))
        }
        #expect(inTransaction.0 == [1, 2, 3])
        #expect(inTransaction.1 == 3)

        if mode != .memoryOnly {
            depot.clearCache()
            #expect(try depot.get(valuesFor: fixture.deep).sorted() == [1, 2, 3])
            #expect(try depot.count(for: fixture.deep) == 3)
        }
    }

    @Test("a value at the prefix alone does not count as a pattern value", arguments: Mode.allCases)
    func prefixValueAlone(mode: Mode) throws {
        let depot = mode.makeDepot()
        let list = Key.from("users", as: [String].self)
        let deep = Key.from("users" / .globstar, as: Int.self)
        depot.register(key: list, coder: .json([String].self))
        depot.register(key: deep, coder: .json(Int.self))
        try depot.set(value: Fixture.storedList, for: list)

        #expect(try depot.has(valuesFor: deep) == false)
        #expect(try depot.count(for: deep) == 0)
        #expect(try depot.get(valuesFor: deep).isEmpty)
    }

    @Test("a trailing globstar registration does not cover the prefix key", arguments: Mode.allCases)
    func registrationDoesNotCoverPrefix(mode: Mode) throws {
        let depot = mode.makeDepot()
        depot.register(key: Key.from("users" / .globstar), coder: .json(Int.self))

        #expect(throws: DepotError.unregisteredKey(keyPath: "users")) {
            try depot.set(value: 1, for: Key.from("users", as: Int.self))
        }
        try depot.set(value: 1, for: Key.from("users" / "alice", as: Int.self))
        #expect(try depot.get(valueFor: Key.from("users" / "alice", as: Int.self)) == 1)
    }

    @Test("removing the pattern keeps the prefix value", arguments: Mode.allCases)
    func removal(mode: Mode) throws {
        let fixture = try Fixture(mode: mode)
        let depot = fixture.depot

        try depot.remove(valuesFor: fixture.deep)

        #expect(try depot.get(valueFor: fixture.list) == Fixture.storedList)
        #expect(try depot.count(for: fixture.deep) == 0)
        #expect(try depot.has(valuesFor: fixture.deep) == false)

        if mode != .memoryOnly {
            depot.clearCache()
            #expect(try depot.get(valueFor: fixture.list) == Fixture.storedList)
            #expect(try depot.count(for: fixture.deep) == 0)
        }
    }

    @Test("removing the pattern in a transaction keeps the prefix value", arguments: Mode.allCases)
    func transactionRemoval(mode: Mode) throws {
        let fixture = try Fixture(mode: mode)
        let depot = fixture.depot

        try depot.transaction { tx in
            try tx.remove(valuesFor: fixture.deep)
            #expect(try tx.get(valueFor: fixture.list) == Fixture.storedList)
            #expect(try tx.count(for: fixture.deep) == 0)
        }

        #expect(try depot.get(valueFor: fixture.list) == Fixture.storedList)
        #expect(try depot.count(for: fixture.deep) == 0)
    }

    @Test("observers of the pattern ignore the prefix value", arguments: Mode.allCases)
    func observation(mode: Mode) async throws {
        let fixture = try Fixture(mode: mode)
        let depot = fixture.depot

        // A failed delivery is recorded as `nil`.
        let snapshots = DeliveryLog<[Int]?>()
        let patternCancellable = depot.core.observe(
            valuesFor: fixture.deep,
            initialValues: true,
            update: { snapshots.append((try? $0.get())?.sorted()) },
            in: depot,
        )
        let listDeliveries = DeliveryLog<[String]?>()
        let listCancellable = depot.core.observe(
            valueFor: fixture.list,
            initialValue: false,
            update: { listDeliveries.append(try? $0.get()) },
            in: depot,
        )
        defer {
            patternCancellable.cancel()
            listCancellable.cancel()
        }
        await depot.waitForPendingObservations()
        #expect(snapshots.all == [[1, 2, 3]])

        // Writing the prefix value must not notify pattern observers.
        try await depot.set(value: ["alice", "bob", "carol"], for: fixture.list)
        await depot.waitForPendingObservations()
        #expect(snapshots.count == 1)

        try await depot.set(value: 4, for: Fixture.user("carol"))
        await depot.waitForPendingObservations()
        #expect(snapshots.all == [[1, 2, 3], [1, 2, 3, 4]])

        // Removing the pattern notifies its observers, but not those of the prefix value.
        let listDeliveriesBeforeRemoval = listDeliveries.count
        try await depot.remove(valuesFor: fixture.deep)
        await depot.waitForPendingObservations()
        #expect(snapshots.last == .some([]))
        #expect(listDeliveries.count == listDeliveriesBeforeRemoval)
        #expect(try await depot.get(valueFor: fixture.list) == ["alice", "bob", "carol"])
    }

    // MARK: - Disk Usage

    @Test("diskUsage counts a distinct prefix with its descendants, and a pattern by its matches")
    func diskUsage() throws {
        let fixture = try Fixture(mode: .fileBacked)
        let depot = fixture.depot

        #expect(try depot.diskUsage(under: Key.from("users")).fileCount == 4)
        #expect(try depot.diskUsage(under: Key.from("users" / .globstar)).fileCount == 3)
        #expect(try depot.diskUsage(under: Key.from("users" / .wildcard)).fileCount == 3)
        #expect(try depot.diskUsage(under: Key.from("users" / .wildcard / .globstar)).fileCount == 1)
        #expect(try depot.diskUsage(under: Key.all).fileCount == 4)
    }
}
