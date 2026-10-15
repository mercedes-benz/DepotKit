// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

private final class TestConfiguration {
    let depots: [Depot]
    let readOnlyDepots: [Depot]
    let baseDepotURL: URL

    init() {
        let encryptionConfiguration = try! EncryptionConfiguration(
            cipher: .aesGCM,
            hashFunction: .sha256,
            key: EncryptionConfiguration.generateKey(),
        )
        baseDepotURL = try! DepotConfiguration.directoryURL(
            in: .caches,
            name: "DepotTests-\(UUID().uuidString)",
        )

        depots = [
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    memoryCache: .disabled
                )
            ),
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    encryption: encryptionConfiguration,
                    memoryCache: .disabled
                )
            ),
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    memoryCache: .default
                )
            ),
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    encryption: encryptionConfiguration,
                    memoryCache: .default
                )
            ),
        ]

        readOnlyDepots = [
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    readOnly: true,
                    memoryCache: .disabled
                )
            ),
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    readOnly: true,
                    encryption: encryptionConfiguration,
                    memoryCache: .disabled
                )
            ),
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    readOnly: true,
                    memoryCache: .default
                )
            ),
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    readOnly: true,
                    encryption: encryptionConfiguration,
                    memoryCache: .default
                )
            ),
        ]
    }

    deinit {
        let baseDepotURL = baseDepotURL

        Task { @concurrent in
            do {
                try FileManager.default.removeItem(at: baseDepotURL)
            } catch {
                // ignore
            }
        }
    }
}

@Suite
struct DepotTests {
    @Suite
    struct DepotImplementations {
        @Suite
        struct RegisteringKeys {
            @Test("is empty")
            func isEmpty() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.depots {
                    #expect(depot.keys.count == 0)
                }
            }

            @Test("contains registered keys")
            func containsRegisteredKeys() async throws {
                let testConfiguration = TestConfiguration()

                let keys: Set<Key> = Set([
                    Key(Key.from("account")),
                    Key(Key.from("entities" / .wildcard / "status")),
                    Key(Key.from("entity" / "default" / "status")),
                ])

                for depot in testConfiguration.depots {
                    for key in keys {
                        let typedKey = depot.register(key: key, coder: .data(String.self))
                        #expect(typedKey.key == key)
                    }

                    #expect(depot.keys == keys)
                }
            }

            @Test("supports keyPath registration overloads")
            func supportsKeyPathRegistrationOverloads() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.depots {
                    let wildcard = depot.register(
                        keyPath: "entity" / .wildcard / "status",
                        coder: .data(String.self),
                    )
                    let wildcardKey = Key.from("entity" / .wildcard / "status")
                    #expect(wildcard.key == wildcardKey)

                    let distinct = depot.register(
                        keyPath: "entity" / "WDB123" / "status",
                        coder: .data(String.self),
                    )
                    try await depot.set(value: "hello world", for: distinct)
                    #expect(try await depot.get(valueFor: distinct) == "hello world")
                }
            }
        }

        @Suite
        struct BasicsTests {
            @Test("work as expected")
            func works() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.depots {
                    let key = depot.register(
                        key: Key.from("entity" / "WDB123" / "status"),
                        coder: .data(String.self),
                    )
                    #expect(try await depot.has(valuesFor: key) == false)
                    #expect(try await depot.get(valueFor: key) == nil)

                    let value = "hello world"
                    try await depot.set(value: value, for: key)

                    #expect(try await depot.has(valuesFor: key))
                    #expect(try await depot.get(valueFor: key) == value)

                    try await depot.remove(valuesFor: key)
                    #expect(try await depot.has(valuesFor: key) == false)
                    #expect(try await depot.get(valueFor: key) == nil)
                }
            }
        }

        @Suite
        struct GetTests {
            @Test("throws if types don't match")
            func throwsIfTypesDoNotMatch() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.depots {
                    do {
                        let key = depot.register(
                            key: Key.from("entity" / "WDB123" / "status"),
                            coder: .data(String.self),
                        )
                        let wrongKey = Key.from("entity" / "WDB123" / "status", as: Date.self)

                        try await depot.set(value: "hello world", for: key)
                        _ = try await depot.get(valueFor: wrongKey)
                        Issue.record("Expected mismatchedTypes error")
                    } catch {
                        guard case let DepotError.mismatchedTypes(keyPath, _, _) = error else {
                            Issue.record("Wrong error type: \(error)")
                            continue
                        }
                        #expect(keyPath == "entity/WDB123/status")
                    }
                }
            }

            @Test("supports top-level key with sub-keys")
            func supportsTopLevelKeyWithSubkeys() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.depots {
                    let topKey = depot.register(
                        key: Key.from("entity"),
                        coder: .data(String.self),
                    )
                    let subKey = depot.register(
                        key: Key.from("entity" / "status"),
                        coder: .data(String.self),
                    )

                    try await depot.set(value: "top", for: topKey)
                    try await depot.set(value: "sub", for: subKey)

                    #expect(try await depot.get(valueFor: topKey) == "top")
                    #expect(try await depot.get(valueFor: subKey) == "sub")
                }
            }
        }

        @Suite
        struct GetValuesTests {
            @Test("returns all values")
            func returnsAllValues() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.depots {
                    let key = depot.register(
                        key: Key.from("entity" / .wildcard / "status"),
                        coder: .data(String.self),
                    )
                    try await depot.set(
                        value: "a",
                        for: Key.from("entity" / "A" / "status", as: String.self),
                    )
                    try await depot.set(
                        value: "b",
                        for: Key.from("entity" / "B" / "status", as: String.self),
                    )
                    try await depot.set(
                        value: "c",
                        for: Key.from("entity" / "C" / "status", as: String.self),
                    )

                    let result = try await depot.get(availableValuesFor: key)
                    #expect(result.values.sorted() == ["a", "b", "c"])
                    #expect(result.errors.isEmpty)
                }
            }

            @Test("returns error if types don't match")
            func returnsErrorIfTypesDoNotMatch() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.depots {
                    let key = depot.register(
                        key: Key.from("entity" / .wildcard / "status"),
                        coder: .data(String.self),
                    )
                    try await depot.set(
                        value: "a",
                        for: Key.from("entity" / "A" / "status", as: String.self),
                    )
                    try await depot.set(
                        value: "b",
                        for: Key.from("entity" / "B" / "status", as: String.self),
                    )

                    let wrongKey = depot.register(
                        key: Key.from("entity" / "C" / "status"),
                        coder: .json(Date.self),
                    )
                    try await depot.set(value: Date(), for: wrongKey)

                    let result = try await depot.get(availableValuesFor: key)
                    #expect(result.values.sorted() == ["a", "b"])
                    #expect(result.keyedErrors.count == 1)

                    let error = try #require(result.keyedErrors.first)
                    if let depotError = error.value as? DepotError,
                        case let .mismatchedTypes(keyPath, _, _) = depotError
                    {
                        #expect(keyPath == "entity/C/status")
                    } else {
                        Issue.record("Wrong error type: \(String(describing: error.value))")
                    }
                    #expect(error.key.key == wrongKey.key)
                }
            }
        }

        @Suite
        struct SetTests {
            @Test("throws if depot is read only")
            func throwsIfDepotIsReadOnly() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.readOnlyDepots {
                    #expect(throws: DepotError.readOnlyDepot) {
                        let key = depot.register(
                            key: Key.from("entity" / "WDB123" / "status"),
                            coder: .data(String.self),
                        )
                        try depot.set(value: "hello world", for: key)
                    }
                }
            }
        }

        @Suite
        struct HasTests {
            @Test("supports wildcard")
            func supportsWildcard() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.depots {
                    depot.register(key: Key.all, coder: .data(String.self))
                    #expect(try await depot.has(valuesFor: Key.all) == false)

                    try await depot.set(
                        value: "lorem ipsum",
                        for: Key.from("test", as: String.self),
                    )
                    #expect(try await depot.has(valuesFor: Key.all))

                    try await depot.set(
                        value: "fine",
                        for: Key.from("entity" / "WDB123" / "status", as: String.self),
                    )
                    #expect(try await depot.has(valuesFor: Key.from("entity" / .wildcard / "status")))
                    #expect(try await depot.has(valuesFor: Key.from("entity" / "WDB123" / .wildcard)))
                    #expect(try await depot.has(valuesFor: Key.from("entity" / "WDB123")) == false)
                }
            }
        }

        @Suite
        struct RemoveTests {
            @Test("throws if depot is read only")
            func throwsIfDepotIsReadOnly() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.readOnlyDepots {
                    #expect(throws: DepotError.readOnlyDepot) {
                        let key = depot.register(
                            key: Key.from("entity" / "WDB123" / "status"),
                            coder: .data(String.self),
                        )
                        try depot.remove(valuesFor: key)
                    }
                }
            }

            @Test("supports wildcard")
            func supportsWildcard() async throws {
                let testConfiguration = TestConfiguration()

                for depot in testConfiguration.depots {
                    depot.register(key: Key.all, coder: .data(String.self))
                    try await depot.set(
                        value: "lorem ipsum",
                        for: Key.from("test", as: String.self),
                    )
                    try await depot.set(
                        value: "fine",
                        for: Key.from("entity" / "A" / "status", as: String.self),
                    )
                    try await depot.set(
                        value: "none",
                        for: Key.from("entity" / "A" / "services", as: String.self),
                    )
                    try await depot.set(
                        value: "damaged",
                        for: Key.from("entity" / "B" / "status", as: String.self),
                    )
                    try await depot.set(
                        value: "on fire",
                        for: Key.from("entity" / "C" / "status", as: String.self),
                    )

                    #expect(try await depot.has(valuesFor: Key.from("entity" / "A" / .wildcard)))
                    try await depot.remove(valuesFor: Key.from("entity" / "A" / .wildcard))
                    #expect(try await depot.has(valuesFor: Key.from("entity" / "A" / .wildcard)) == false)

                    #expect(try await depot.has(valuesFor: Key.from("entity" / .wildcard / "status")))
                    try await depot.remove(valuesFor: Key.from("entity" / .wildcard / "status"))
                    #expect(try await depot.has(valuesFor: Key.from("entity" / .wildcard / "status")) == false)

                    #expect(try await depot.has(valuesFor: Key.all))
                    try await depot.remove(valuesFor: Key.all)
                    #expect(try await depot.has(valuesFor: Key.all) == false)
                }
            }
        }

    }
}
