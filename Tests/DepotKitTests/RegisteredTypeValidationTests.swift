// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

enum ValidationStorageMode: String, CaseIterable, Sendable {
    case memory
    case file

    func makeDepot() -> Depot {
        switch self {
        case .memory:
            Depot()
        case .file:
            Depot.temporary()
        }
    }
}

enum ValidationRegistration: String, CaseIterable, Sendable {
    case exact
    case pattern

    /// Registers `Int` either at the exact path or via a covering pattern and
    /// returns the distinct `Int` key used by the tests.
    @discardableResult
    func register(in depot: Depot) -> TypedDistinctKey<Int> {
        switch self {
        case .exact:
            return depot.register(keyPath: "settings" / "count", coder: .json(Int.self))
        case .pattern:
            depot.register(keyPath: "counters" / .wildcard, coder: .json(Int.self))
            return Key.from("counters" / "a", as: Int.self)
        }
    }
}

enum ValidationEntryPoint: String, CaseIterable, Sendable {
    case sync
    case async
}

/// Counts every observer delivery for the given keys.
final class DeliveryCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    private let cancellables = OSAllocatedUnfairLock(initialState: [any DepotCancellable]())

    var value: Int { count.withLock { $0 } }

    func observe(_ key: TypedDistinctKey<Int>, pattern: TypedKey<Int>? = nil, in depot: Depot) {
        let count = count
        let increment: @Sendable () -> Void = { count.withLock { $0 += 1 } }

        var observations = [any DepotCancellable]()
        observations.append(
            depot.core.observe(valueFor: key, initialValue: false, update: { _ in increment() }, in: depot)
        )
        observations.append(
            depot.core.observe(
                valuesFor: TypedKey<Int>(key),
                initialValues: false,
                update: { _ in increment() },
                in: depot
            )
        )
        if let pattern {
            observations.append(
                depot.core.observe(valuesFor: pattern, initialValues: false, update: { _ in increment() }, in: depot)
            )
        }
        let registered = observations
        cancellables.withLock { $0.append(contentsOf: registered) }
    }

    func cancel() {
        for cancellable in cancellables.withLock({ $0 }) {
            cancellable.cancel()
        }
    }
}

private func removeDirectory(of depot: Depot) {
    if let url = depot.configuration.directoryURL {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Write validation

/// Regression tests: writes must validate the registered value type
/// in every storage mode, before mutating storage or notifying observers.
@Suite
struct RegisteredTypeWriteValidationTests {
    @Test(
        "wrong-type writes fail without changing the value or notifying observers",
        arguments: ValidationStorageMode.allCases,
        ValidationRegistration.allCases,
    )
    func wrongTypeWriteIsRejected(mode: ValidationStorageMode, registration: ValidationRegistration) async throws {
        for entryPoint in ValidationEntryPoint.allCases {
            for writesNil in [false, true] {
                let depot = mode.makeDepot()
                defer { removeDirectory(of: depot) }

                let intKey = registration.register(in: depot)
                try await depot.set(value: 7, for: intKey)

                let counter = DeliveryCounter()
                defer { counter.cancel() }
                counter.observe(intKey, in: depot)

                let stringKey = TypedDistinctKey<String>(intKey)
                let expectedError = DepotError.mismatchedTypes(
                    keyPath: intKey.keyPath,
                    expected: "String",
                    actual: "Int",
                )
                let value: String? = writesNil ? nil : "not an int"

                switch entryPoint {
                case .sync:
                    #expect(throws: expectedError) {
                        try depot.set(value: value, for: stringKey)
                    }
                case .async:
                    await #expect(throws: expectedError) {
                        try await depot.set(value: value, for: stringKey)
                    }
                }

                await depot.waitForPendingObservations()

                let context: Comment = "mode=\(mode) registration=\(registration) entry=\(entryPoint) nil=\(writesNil)"
                #expect(try await depot.get(valueFor: intKey) == 7, context)
                #expect(try await depot.get(valuesFor: TypedKey<Int>(intKey)) == [7], context)
                #expect(counter.value == 0, context)
            }
        }
    }

    @Test(
        "correctly typed writes still succeed and notify observers",
        arguments: ValidationStorageMode.allCases,
        ValidationRegistration.allCases,
    )
    func correctlyTypedWriteSucceeds(mode: ValidationStorageMode, registration: ValidationRegistration) async throws {
        let depot = mode.makeDepot()
        defer { removeDirectory(of: depot) }

        let intKey = registration.register(in: depot)
        let counter = DeliveryCounter()
        defer { counter.cancel() }
        counter.observe(intKey, in: depot)

        try await depot.set(value: 1, for: intKey)
        try await depot.set(value: 2, for: intKey)
        await depot.waitForPendingObservations()

        #expect(try await depot.get(valueFor: intKey) == 2)
        #expect(counter.value == 4)
    }

    @Test("unregistered writes fail in every storage mode", arguments: ValidationStorageMode.allCases)
    func unregisteredWriteIsRejected(mode: ValidationStorageMode) async throws {
        let depot = mode.makeDepot()
        defer { removeDirectory(of: depot) }

        let key = Key.from("unregistered" / "value", as: Int.self)
        let expectedError = DepotError.unregisteredKey(keyPath: key.keyPath)

        #expect(throws: expectedError) { try depot.set(value: 1, for: key) }
        await #expect(throws: expectedError) { try await depot.set(value: 1, for: key) }
        #expect(throws: expectedError) { try depot.set(value: nil, for: key) }
    }
}

// MARK: - Transaction write validation

/// Regression tests: transaction writes must validate registration
/// and the registered value type when buffered, in every storage mode.
@Suite
struct TransactionWriteValidationTests {
    enum InvalidWrite: String, CaseIterable, Sendable {
        case unregistered
        case wrongType
        case unregisteredNil
        case wrongTypeNil
    }

    private struct Fixture {
        let depot: Depot
        let countKey: TypedDistinctKey<Int>
        let pattern: TypedKey<Int>
        let patternItem: TypedDistinctKey<Int>

        init(mode: ValidationStorageMode) throws {
            depot = mode.makeDepot()
            countKey = depot.register(keyPath: "settings" / "count", coder: .json(Int.self))
            pattern = depot.register(keyPath: "counters" / .wildcard, coder: .json(Int.self))
            patternItem = Key.from("counters" / "a", as: Int.self)
            try depot.set(value: 1, for: countKey)
        }

        func performInvalidWrite(_ write: InvalidWrite, in transaction: inout DepotTransaction) throws {
            switch write {
            case .unregistered:
                try transaction.set(value: 1, for: Key.from("unregistered" / "value", as: Int.self))
            case .wrongType:
                try transaction.set(value: "not an int", for: TypedDistinctKey<String>(countKey))
            case .unregisteredNil:
                try transaction.set(value: nil, for: Key.from("unregistered" / "value", as: Int.self))
            case .wrongTypeNil:
                try transaction.set(value: nil, for: TypedDistinctKey<String>(countKey))
            }
        }

        func expectedError(for write: InvalidWrite) -> DepotError {
            switch write {
            case .unregistered, .unregisteredNil:
                .unregisteredKey(keyPath: "unregistered/value")
            case .wrongType, .wrongTypeNil:
                .mismatchedTypes(keyPath: countKey.keyPath, expected: "String", actual: "Int")
            }
        }
    }

    @Test(
        "invalid writes throw at the call site and an escaping error rolls back the transaction",
        arguments: ValidationStorageMode.allCases,
        InvalidWrite.allCases,
    )
    func invalidWriteRollsBack(mode: ValidationStorageMode, write: InvalidWrite) async throws {
        for entryPoint in ValidationEntryPoint.allCases {
            let fixture = try Fixture(mode: mode)
            let depot = fixture.depot
            defer { removeDirectory(of: depot) }

            let counter = DeliveryCounter()
            defer { counter.cancel() }
            counter.observe(fixture.countKey, pattern: fixture.pattern, in: depot)
            counter.observe(fixture.patternItem, in: depot)

            let expectedError = fixture.expectedError(for: write)
            let thrownAtCallSite = OSAllocatedUnfairLock<DepotError?>(initialState: nil)
            let work: @Sendable (inout DepotTransaction) throws -> Void = { transaction in
                try transaction.set(value: 2, for: fixture.countKey)
                try transaction.set(value: 5, for: fixture.patternItem)
                do {
                    try fixture.performInvalidWrite(write, in: &transaction)
                } catch {
                    thrownAtCallSite.withLock { $0 = error as? DepotError }
                    throw error
                }
            }

            switch entryPoint {
            case .sync:
                #expect(throws: expectedError) { try depot.transaction(work) }
            case .async:
                await #expect(throws: expectedError) { try await depot.transaction(work) }
            }

            await depot.waitForPendingObservations()

            let context: Comment = "mode=\(mode) write=\(write) entry=\(entryPoint)"
            #expect(thrownAtCallSite.withLock { $0 } == expectedError, context)
            #expect(try await depot.get(valueFor: fixture.countKey) == 1, context)
            #expect(try await depot.get(valueFor: fixture.patternItem) == nil, context)
            #expect(try await depot.get(valuesFor: fixture.pattern) == [], context)
            #expect(counter.value == 0, context)
        }
    }

    @Test(
        "an invalid write caught inside the transaction is not buffered",
        arguments: ValidationStorageMode.allCases,
        InvalidWrite.allCases,
    )
    func caughtInvalidWriteIsNotBuffered(mode: ValidationStorageMode, write: InvalidWrite) async throws {
        let fixture = try Fixture(mode: mode)
        let depot = fixture.depot
        defer { removeDirectory(of: depot) }

        try await depot.transaction { transaction in
            try transaction.set(value: 5, for: fixture.patternItem)
            #expect(throws: fixture.expectedError(for: write)) {
                try fixture.performInvalidWrite(write, in: &transaction)
            }
        }

        #expect(try await depot.get(valueFor: fixture.countKey) == 1)
        #expect(try await depot.get(valueFor: fixture.patternItem) == 5)
        #expect(try await depot.has(valuesFor: Key.from("unregistered" / "value")) == false)
    }

    @Test(
        "registered pattern-covered keys can be written in transactions",
        arguments: ValidationStorageMode.allCases,
    )
    func patternCoveredKeysStillWork(mode: ValidationStorageMode) async throws {
        let fixture = try Fixture(mode: mode)
        let depot = fixture.depot
        defer { removeDirectory(of: depot) }

        let counter = DeliveryCounter()
        defer { counter.cancel() }
        counter.observe(fixture.patternItem, pattern: fixture.pattern, in: depot)

        let other = Key.from("counters" / "b", as: Int.self)
        try await depot.transaction { transaction in
            try transaction.set(value: 5, for: fixture.patternItem)
            try transaction.set(value: 6, for: other)
            try transaction.set(value: 2, for: fixture.countKey)
        }
        try await depot.transaction { transaction in
            try transaction.set(value: nil, for: other)
        }
        await depot.waitForPendingObservations()

        #expect(try await depot.get(valueFor: fixture.patternItem) == 5)
        #expect(try await depot.get(valueFor: other) == nil)
        #expect(try await depot.get(valueFor: fixture.countKey) == 2)
        #expect(try await depot.get(valuesFor: fixture.pattern) == [5])
        #expect(counter.value > 0)
    }
}
