// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// `removeExpired()` notifies observers once for all values it removes, so a pattern observer
/// re-reads its family once instead of once per expired value.
@Suite("Expiry notifications")
struct ExpiryNotificationTests {
    enum StorageMode: String, CaseIterable, Sendable {
        case memory
        case file
        case fileCached

        func makeDepot(clock: MockClock) -> Depot {
            switch self {
            case .memory:
                Depot(label: "test", configuration: .inMemory(), overrides: .init(clock: clock))
            case .file:
                Depot.temporary(memoryCache: .disabled, clock: clock)
            case .fileCached:
                Depot.temporary(memoryCache: .default, clock: clock)
            }
        }
    }

    static let names = (0..<10).map { "item\($0)" }

    static func item(_ name: String) -> TypedDistinctKey<String> {
        Key.from("items" / name, as: String.self)
    }

    @Test("observers are notified once when several values expire at once", arguments: StorageMode.allCases)
    func expiredValuesNotifyOnce(mode: StorageMode) async throws {
        let clock = MockClock()
        let depot = mode.makeDepot(clock: clock)
        defer {
            if let url = depot.configuration.directoryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let pattern = depot.register(keyPath: "items" / .wildcard, coder: .json(String.self), expiry: .seconds(60))
        let kept = depot.register(keyPath: "kept", coder: .json(String.self))
        for name in Self.names {
            try await depot.set(value: name, for: Self.item(name))
        }
        try await depot.set(value: "kept", for: kept)

        let family = DeliveryLog<Set<String>>()
        let first = DeliveryLog<String?>()
        let unrelated = DeliveryLog<String?>()
        let cancellables = [
            depot.core.observe(
                valuesFor: pattern,
                initialValues: true,
                update: { family.append(Set((try? $0.get()) ?? ["<error>"])) },
                in: depot,
            ),
            depot.core.observe(
                valueFor: Self.item(Self.names[0]),
                initialValue: true,
                update: { first.append(DeliveryLog.value(of: $0)) },
                in: depot,
            ),
            depot.core.observe(
                valueFor: kept,
                initialValue: true,
                update: { unrelated.append(DeliveryLog.value(of: $0)) },
                in: depot,
            ),
        ]
        defer {
            for cancellable in cancellables {
                cancellable.cancel()
            }
        }
        await depot.waitForPendingObservations()
        #expect(family.last == Set(Self.names))
        let counts = (family.count, first.count, unrelated.count)

        clock.advance(by: 61)
        #expect(try await depot.removeExpired() == Self.names.count)
        await depot.waitForPendingObservations()

        #expect(family.count == counts.0 + 1, "one notification for all expired values")
        #expect(family.last == [])
        #expect(first.count == counts.1 + 1)
        #expect(first.last == .some(nil))
        #expect(unrelated.count == counts.2, "the unexpired value was not removed")
    }
}
