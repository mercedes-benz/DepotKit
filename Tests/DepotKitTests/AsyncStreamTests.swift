// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite("AsyncStream observation")
struct AsyncStreamTests {
    // MARK: - values(for:) distinct key

    @Test("values(for:) emits initial value")
    func valuesForKeyEmitsInitialValue() async throws {
        let depot = Depot.temporary()
        let key = depot.register(key: Key.from("counter"), coder: .data(Int.self))
        try await depot.set(value: 42, for: key)

        var iterator = depot.values(for: key, initialValue: true).makeAsyncIterator()

        let change = await iterator.next()
        switch change {
        case .some(.success(let value)):
            #expect(value == 42)
        default:
            Issue.record("Expected .success(42), got \(String(describing: change))")
        }
    }

    @Test("values(for:) emits updates")
    func valuesForKeyEmitsUpdates() async throws {
        let depot = Depot.temporary()
        let key = depot.register(key: Key.from("name"), coder: .data(String.self))

        let stream = depot.values(for: key, initialValue: false)
        var iterator = stream.makeAsyncIterator()

        try await depot.set(value: "alice", for: key)
        await depot.waitForPendingObservations()

        let change = await iterator.next()
        switch change {
        case .some(.success(let value)):
            #expect(value == "alice")
        default:
            Issue.record("Expected .success(\"alice\"), got \(String(describing: change))")
        }
    }

    @Test("values(for:) emits absent when value is removed")
    func valuesForKeyEmitsAbsentOnRemoval() async throws {
        let depot = Depot.temporary()
        let key = depot.register(key: Key.from("flag"), coder: .data(String.self))
        try await depot.set(value: "present", for: key)

        let stream = depot.values(for: key, initialValue: false)
        var iterator = stream.makeAsyncIterator()

        try await depot.set(value: nil, for: key)
        await depot.waitForPendingObservations()

        let change = await iterator.next()
        switch change {
        case .some(.success(nil)):
            break  // correct
        default:
            Issue.record("Expected .success(nil), got \(String(describing: change))")
        }
    }

    // MARK: - values(for:) wildcard key

    @Test("values(for:) wildcard emits initial values")
    func valuesForWildcardKeyEmitsInitialValues() async throws {
        let depot = Depot.temporary()
        let patternKey = depot.register(key: Key.from("items" / .wildcard), coder: .data(String.self))

        try await depot.set(value: "a", for: Key.from("items" / "A", as: String.self))
        try await depot.set(value: "b", for: Key.from("items" / "B", as: String.self))

        var iterator = depot.values(for: patternKey, initialValues: true).makeAsyncIterator()

        let result = await iterator.next()
        switch result {
        case .some(.success(let values)):
            #expect(values.sorted() == ["a", "b"])
        default:
            Issue.record("Expected two values, got \(String(describing: result))")
        }
    }

    @Test("values(for:) wildcard emits on update")
    func valuesForWildcardKeyEmitsOnUpdate() async throws {
        let depot = Depot.temporary()
        let patternKey = depot.register(key: Key.from("scores" / .wildcard), coder: .data(Int.self))

        let stream = depot.values(for: patternKey, initialValues: false)
        var iterator = stream.makeAsyncIterator()

        try await depot.set(value: 10, for: Key.from("scores" / "player1", as: Int.self))
        await depot.waitForPendingObservations()

        let result = await iterator.next()
        switch result {
        case .some(.success(let values)):
            #expect(values == [10])
        default:
            Issue.record("Expected [10], got \(String(describing: result))")
        }
    }

}
