// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite("Observer reentrancy and convergence", .offCooperativePool)
struct ObserverReentrancyAndConvergenceTests {
    enum ObserverKind: String, CaseIterable, Sendable {
        case single
        case multi
        case available

        /// Observes `key` and forwards the delivered value (or `nil`), or the delivery's error, to `update`.
        func observe(
            _ key: TypedDistinctKey<Int>,
            initialValue: Bool,
            in depot: Depot,
            update: @escaping @Sendable (Result<Int?, any Error>) async -> Void,
        ) -> any DepotCancellable {
            switch self {
            case .single:
                depot.core.observe(
                    valueFor: key,
                    initialValue: initialValue,
                    update: { await update($0) },
                    in: depot,
                )
            case .multi:
                depot.core.observe(
                    valuesFor: key,
                    initialValues: initialValue,
                    update: { await update($0.map(\.first)) },
                    in: depot,
                )
            case .available:
                depot.core.observe(
                    availableValuesFor: key,
                    initialValues: initialValue,
                    update: { result in
                        await update(
                            result.flatMap { available in
                                if let error = available.errors.first {
                                    return .failure(error)
                                }
                                return .success(available.values.first)
                            },
                        )
                    },
                    in: depot,
                )
            }
        }
    }

    private static func makeDepot(fileBacked: Bool) -> Depot {
        fileBacked ? Depot.temporary(memoryCache: .default) : Depot()
    }

    private static func removeDirectory(of depot: Depot) {
        if let url = depot.configuration.directoryURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test(
        "observer callbacks can write to the depot and register observers",
        arguments: [false, true],
        ObserverKind.allCases,
    )
    func reentrantCallbacks(fileBacked: Bool, kind: ObserverKind) async throws {
        let depot = Self.makeDepot(fileBacked: fileBacked)
        defer { Self.removeDirectory(of: depot) }
        let key = depot.register(keyPath: "value", coder: .json(Int.self))

        for initialValue in [false, true] {
            try await depot.remove(valueFor: key)
            await depot.waitForPendingObservations()
            let log = DeliveryLog<Int?>()
            if initialValue {
                try await depot.set(value: 1, for: key)
            }
            let cancellable = kind.observe(key, initialValue: initialValue, in: depot) { result in
                let value: Int?
                do {
                    value = try result.get()
                } catch {
                    Issue.record(error, "delivery failed (initialValue: \(initialValue))")
                    return
                }
                log.append(value)
                guard value == 1 else {
                    return
                }
                do {
                    try depot.set(value: 2, for: key)
                    let nested = depot.core.observe(valueFor: key, initialValue: false, update: { _ in }, in: depot)
                    nested.cancel()
                } catch {
                    Issue.record(error)
                }
            }
            defer { cancellable.cancel() }
            if !initialValue {
                try await depot.set(value: 1, for: key)
            }

            #expect(await waitUntil { log.last == 2 })
            await depot.waitForPendingObservations()
            #expect(log.all == [1, 2], "initialValue: \(initialValue)")

            cancellable.cancel()
            try await depot.set(value: 3, for: key)
            await depot.waitForPendingObservations()
            #expect(log.all == [1, 2], "initialValue: \(initialValue)")
        }
    }

    @Test("an observer of parallel writers ends at the stored value", arguments: [false, true])
    func parallelWriters(fileBacked: Bool) async throws {
        let depot = Self.makeDepot(fileBacked: fileBacked)
        defer { Self.removeDirectory(of: depot) }
        let key = depot.register(keyPath: "value", coder: .json(Int.self))
        let log = DeliveryLog<Int?>()
        let cancellable = depot.core.observe(
            valueFor: key,
            initialValue: false,
            update: { log.append(try? $0.get()) },
            in: depot,
        )
        defer { cancellable.cancel() }

        for round in 0..<10 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for value in 0..<100 {
                    group.addTask { try await depot.set(value: value, for: key) }
                }
                try await group.waitForAll()
            }
            await depot.waitForPendingObservations()

            let stored = try await depot.get(valueFor: key)
            #expect(stored != nil)
            #expect(log.last == stored, "round \(round)")
            #expect(log.count == (round + 1) * 100, "round \(round)")
        }

        cancellable.cancel()
        try await depot.set(value: -1, for: key)
        await depot.waitForPendingObservations()
        #expect(log.count == 1000)
    }

    @Test(
        "recreated metadata is not reported as a removal by later external-change checks",
        arguments: [false, true],
        [false, true],
    )
    func metadataRecreationAndRecheck(cacheEnabled: Bool, removeAll: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let configuration = DepotConfiguration(
            directoryURL: url,
            enableMultiProcessSupport: true,
            memoryCache: cacheEnabled ? .default : .disabled,
        )
        let depot = Depot(configuration: configuration, overrides: .init(initSweepDelay: .seconds(3600)))
        let peer = Depot(configuration: configuration, overrides: .init(initSweepDelay: .seconds(3600)))
        let family = depot.register(key: Key.all, coder: .json(Int.self))
        let peerFamily = peer.register(key: Key.all, coder: .json(Int.self))
        let key = Key.from("value", as: Int.self)

        try await depot.set(value: 7, for: key)
        try await peer.checkForExternalChanges()
        #expect(try await peer.get(valuesFor: peerFamily) == [7])

        let values = DeliveryLog<[Int]>()
        let available = DeliveryLog<[Int]>()
        let single = DeliveryLog<Int?>()
        let cancellables = [
            depot.core.observe(
                valuesFor: family,
                initialValues: false,
                update: { values.append((try? $0.get().sorted()) ?? [-1]) },
                in: depot,
            ),
            depot.core.observe(
                availableValuesFor: family,
                initialValues: false,
                update: { available.append((try? $0.get().keyedValues.values.sorted()) ?? [-1]) },
                in: depot,
            ),
            depot.core.observe(
                valueFor: key,
                initialValue: false,
                update: { single.append(try? $0.get()) },
                in: depot,
            ),
        ]
        defer {
            for cancellable in cancellables {
                cancellable.cancel()
            }
        }

        if removeAll {
            try await depot.remove(valuesFor: Key.all)
        } else {
            try await depot.reset()
        }
        await depot.waitForPendingObservations()
        #expect(values.all == [[]])
        #expect(available.all == [[]])
        #expect(single.all == [nil])
        try await depot.verifyIntegrity()

        let metadataURL = try #require(depot.metadataFileURL)
        let metadata = try Data(contentsOf: metadataURL)
        for _ in 0..<2 {
            try await depot.checkForExternalChanges()
            await depot.waitForPendingObservations()
            #expect(values.all == [[]])
            #expect(available.all == [[]])
            #expect(single.all == [nil])
            #expect(try Data(contentsOf: metadataURL) == metadata)
        }

        try await peer.checkForExternalChanges()
        #expect(try await peer.get(valuesFor: peerFamily).isEmpty)
        try await peer.verifyIntegrity()

        try await peer.set(value: 9, for: key)
        try await depot.checkForExternalChanges()
        await depot.waitForPendingObservations()
        #expect(values.all == [[], [9]])
        #expect(available.all == [[], [9]])
        #expect(single.all == [nil, 9])
    }
}
