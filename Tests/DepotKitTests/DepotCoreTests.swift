// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct DepotCoreTests {
    @Suite
    struct SortedKeys {
        @Test("works as expected")
        func worksAsExpected() async throws {
            let depot = Depot(label: "SortedKeysTest")
            #expect(depot.keys.count == 0)

            let key1 = Key.from("entities" / .wildcard)
            let key2 = Key.from("entities" / .wildcard / "status")
            let key3 = Key.from("accounts").key

            depot.register(key: key1, coder: .data(String.self))
            depot.register(key: key2, coder: .data(String.self))
            depot.register(key: key3, coder: .json(Date.self))

            #expect(depot.keys == Set([key1, key2, key3]))
            #expect(depot.keys.sorted() == [key3, key1, key2])
        }
    }

    @Suite
    struct RegisteredCoders {
        @Test("throws when not registered")
        func throwsWhenNotRegistered() async throws {
            let depot = Depot(label: "CoderTest")
            let key = Key.from("unknown").key.typed(as: String.self)

            #expect(throws: DepotError.unregisteredKey(keyPath: "unknown")) {
                _ = try depot.core.coder(for: key.key, as: String.self)
            }
        }

        @Test("throws mismatched types")
        func throwsMismatchedTypes() async throws {
            let depot = Depot(label: "CoderTest")
            let key = depot.register(
                key: Key.from("entities" / .wildcard / "status"),
                coder: .data(String.self),
            )

            do {
                _ = try depot.core.coder(for: key.key, as: [String].self)
                Issue.record("Expected mismatchedTypes error")
            } catch {
                guard case let DepotError.mismatchedTypes(keyPath, _, _) = error else {
                    Issue.record("Wrong error type: \(error)")
                    return
                }
                #expect(keyPath == "entities/*/status")
            }
        }

        @Test("uses encryptionConfiguration")
        func usesEncryptionConfiguration() async throws {
            let encryptionConfiguration = try EncryptionConfiguration(
                cipher: .aesGCM,
                hashFunction: .sha256,
                key: EncryptionConfiguration.generateKey(),
            )
            let depot = Depot(
                configuration: .init(
                    directoryURL: try DepotConfiguration.directoryURL(
                        in: .caches,
                        name: "DepotCoreTests-Enc-\(UUID().uuidString)"
                    ),
                    encryption: encryptionConfiguration
                )
            )

            let key = Key.from("entities" / .wildcard / "status")
            let coder: AnyCoder<String> = .data()

            let typedKey = depot.register(key: key, coder: coder)

            let value = "hello world"
            let encoded = try coder.encode(value)
            #expect(try depot.core.coder(for: typedKey.key, as: String.self).encode(value) != encoded)
        }

        @Test("prefers most specific wildcard match")
        func prefersMostSpecificWildcardMatch() async throws {
            let depot = Depot(label: "CoderTest")

            _ = depot.register(key: Key.from("entities" / .wildcard), coder: .json() as AnyCoder<String>)
            _ = depot.register(
                key: Key.from("entities" / .wildcard / "status"),
                coder: .plist() as AnyCoder<String>,
            )

            let requestKey = Key.from("entities" / "WDB123" / "status").key
            let coder: AnyCoder<String> = try depot.core.coder(for: requestKey, as: String.self)

            #expect(coder.coderDescription.contains("plist"))
        }

        @Test("prefers concrete over wildcard")
        func prefersConcreteOverWildcard() async throws {
            let depot = Depot(label: "CoderTest")

            _ = depot.register(
                key: Key.from("entities" / .wildcard / "status"),
                coder: .json() as AnyCoder<String>,
            )
            _ = depot.register(
                key: Key.from("entities" / "WDB123" / .wildcard),
                coder: .plist() as AnyCoder<String>,
            )

            let requestKey = Key.from("entities" / "WDB123" / "status").key
            let coder: AnyCoder<String> = try depot.core.coder(for: requestKey, as: String.self)

            #expect(coder.coderDescription.contains("plist"))
        }
    }

    @Suite
    struct Observers {
        @Test("observer receives updates and removals via public API")
        func observerReceivesUpdatesAndRemovals() async throws {
            let depot = Depot(label: "ObserverTest")

            _ = depot.register(
                key: Key.from("entities" / .wildcard / "status"),
                coder: .data(String.self),
            )
            let accountsKey = depot.register(key: Key.from("accounts"), coder: .data(String.self))

            let statusKey = Key.from("entities" / "WDB123" / "status", as: String.self)

            let receivedValues = OSAllocatedUnfairLock<[String?]>(initialState: [])
            let stream = depot.values(for: statusKey, initialValue: false)
            let task = Task {
                for await result in stream {
                    switch result {
                    case .success(let v): receivedValues.withLock { $0.append(v) }
                    case .failure: Issue.record()
                    }
                }
            }

            // Write to unrelated key — should NOT trigger our observer
            try await depot.set(value: "unexpected", for: accountsKey)
            await depot.waitForPendingObservations()

            // Write to matching key — should trigger
            try await depot.set(value: "update", for: statusKey)
            await depot.waitForPendingObservations()
            #expect(await waitUntil { receivedValues.withLock { $0.count >= 1 } })

            // Remove via globstar — should trigger nil
            try await depot.remove(valuesFor: Key.from("entities" / .globstar))
            await depot.waitForPendingObservations()
            #expect(await waitUntil { receivedValues.withLock { $0.count >= 2 } })

            // Write again — should trigger
            try await depot.set(value: "second", for: statusKey)
            await depot.waitForPendingObservations()
            #expect(await waitUntil { receivedValues.withLock { $0.count >= 3 } })

            // Remove specific key — should trigger nil
            try await depot.remove(valueFor: statusKey)
            await depot.waitForPendingObservations()
            #expect(await waitUntil { receivedValues.withLock { $0.count >= 4 } })

            task.cancel()
            await task.value

            let receivedValuesFinal = receivedValues.withLock { $0 }
            #expect(receivedValuesFinal == ["update", nil, "second", nil])
        }
    }
}
