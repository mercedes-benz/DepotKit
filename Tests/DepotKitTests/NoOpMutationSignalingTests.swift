// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// Other processes are signaled by touching the shared lock file. Mutations that leave the files on
/// disk unchanged must not signal, so peers do not scan for changes that do not exist.
@Suite("Lock file signaling of no-op mutations", .offCooperativePool)
struct NoOpMutationSignalingTests {
    typealias Support = BulkRemovalSupport

    struct Fixture {
        let url: URL
        let depot: Depot
        let stored: TypedDistinctKey<Int>
        let missing: TypedDistinctKey<Int>

        init() throws {
            url = Support.temporaryDirectory()
            depot = Support.makeDepot(at: url)
            depot.register(key: Key.all, coder: .json(Int.self))
            stored = Key.from("items" / "stored", as: Int.self)
            missing = Key.from("items" / "missing", as: Int.self)
            try depot.set(value: 1, for: stored)
            try Support.backdateLockFile(in: url)
        }

        var lockWasTouched: Bool {
            (Support.lockFileModificationDate(in: url) ?? .distantPast) > Date(timeIntervalSince1970: 1_000_000)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    enum NoOp: String, CaseIterable, Sendable {
        case setNil
        case removeValue
        case removeValues
        case transactionRemove
        case transactionRemoveValues
        case transactionSetNil
        case emptyTransaction

        func perform(on fixture: Fixture) throws {
            let depot = fixture.depot
            let missing = fixture.missing
            switch self {
            case .setNil:
                try depot.set(value: nil, for: missing)
            case .removeValue:
                try depot.remove(valueFor: missing)
            case .removeValues:
                try depot.remove(valuesFor: Key.from("other" / .wildcard))
            case .transactionRemove:
                try depot.transaction { try $0.remove(valueFor: missing) }
            case .transactionRemoveValues:
                try depot.transaction { try $0.remove(valuesFor: Key.from("other" / .wildcard)) }
            case .transactionSetNil:
                try depot.transaction { try $0.set(value: nil, for: missing) }
            case .emptyTransaction:
                try depot.transaction { _ in }
            }
        }
    }

    @Test("mutations that change no file do not touch the lock file", arguments: NoOp.allCases)
    func noOpDoesNotSignal(noOp: NoOp) throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try noOp.perform(on: fixture)

        #expect(!fixture.lockWasTouched)
        #expect(try fixture.depot.get(valueFor: fixture.stored) == 1)
    }

    @Test("removing a stored value with set(nil) touches the lock file")
    func setNilOfStoredValueSignals() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try fixture.depot.set(value: nil, for: fixture.stored)

        #expect(fixture.lockWasTouched)
        #expect(try fixture.depot.get(valueFor: fixture.stored) == nil)
    }

    @Test("a transaction removing a stored and a missing value touches the lock file")
    func transactionWithEffectiveRemovalSignals() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try fixture.depot.transaction { transaction in
            try transaction.remove(valueFor: fixture.missing)
            try transaction.remove(valueFor: fixture.stored)
        }

        #expect(fixture.lockWasTouched)
        #expect(try fixture.depot.get(valueFor: fixture.stored) == nil)
    }

    @Test("set(nil) of a missing value still notifies its observers")
    func setNilStillNotifies() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let log = DeliveryLog<Int?>()
        let cancellable = fixture.depot.core.observe(
            valueFor: fixture.missing,
            initialValue: false,
            update: { log.append(try? $0.get()) },
            in: fixture.depot,
        )
        defer { cancellable.cancel() }

        try await fixture.depot.set(value: nil, for: fixture.missing)
        await fixture.depot.waitForPendingObservations()

        #expect(log.all == [nil])
        #expect(!fixture.lockWasTouched)
    }
}
