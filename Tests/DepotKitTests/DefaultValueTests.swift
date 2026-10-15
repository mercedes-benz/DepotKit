// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct DefaultValueTests {
    // MARK: - Synchronous Depot.get(valueFor:default:)

    @Suite
    struct SyncDefaultValue {
        @Test("returns stored value when it exists")
        func returnsStoredValue() throws {
            let depot = Depot.temporary()
            let key = depot.register(
                key: Key.from("username"),
                coder: .data(String.self),
            )

            try depot.set(value: "Alice", for: key)

            let result = try depot.get(valueFor: key, default: "Anonymous")
            #expect(result == "Alice")
        }

        @Test("returns default value when no value exists")
        func returnsDefaultWhenNil() throws {
            let depot = Depot.temporary()
            let key = depot.register(
                key: Key.from("username"),
                coder: .data(String.self),
            )

            let result = try depot.get(valueFor: key, default: "Anonymous")
            #expect(result == "Anonymous")
        }

        @Test("returns default after value is removed")
        func returnsDefaultAfterRemoval() throws {
            let depot = Depot.temporary()
            let key = depot.register(
                key: Key.from("setting"),
                coder: .data(String.self),
            )

            try depot.set(value: "dark", for: key)
            try depot.remove(valuesFor: key)

            let result = try depot.get(valueFor: key, default: "light")
            #expect(result == "light")
        }

        @Test("does not evaluate default when value exists (autoclosure)")
        func defaultIsLazy() throws {
            let depot = Depot.temporary()
            let key = depot.register(
                key: Key.from("count"),
                coder: .data(String.self),
            )

            try depot.set(value: "42", for: key)

            var evaluated = false
            let result = try depot.get(
                valueFor: key,
                default: {
                    evaluated = true
                    return "0"
                }(),
            )
            #expect(result == "42")
            #expect(evaluated == false)
        }

        @Test("throws unregisteredKey for unregistered key even with default")
        func throwsForUnregisteredKey() throws {
            let url = try DepotConfiguration.directoryURL(
                in: .temporary,
                name: "DefaultValueTests-unreg-\(UUID().uuidString)",
            )
            defer { try? FileManager.default.removeItem(at: url) }

            let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))

            // Register and store with one key, then read with a different unregistered key
            let registeredKey = depot.register(
                key: Key.from("registered"),
                coder: .data(String.self),
            )
            try depot.set(value: "data", for: registeredKey)

            // Write a file at the unregistered key's path manually so Depot finds a file
            let unregisteredKey = Key.from("unregistered", as: String.self)
            let fileURL = try depot.fileURL(for: Key.from("unregistered"))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try "bogus".data(using: .utf8)!.write(to: fileURL)

            #expect(throws: DepotError.unregisteredKey(keyPath: "unregistered")) {
                _ = try depot.get(valueFor: unregisteredKey, default: "fallback")
            }
        }

        @Test("works with Depot")
        func worksWithDepot() throws {
            let url = try DepotConfiguration.directoryURL(
                in: .temporary,
                name: "DefaultValueTests-\(UUID().uuidString)",
            )
            defer { try? FileManager.default.removeItem(at: url) }

            let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
            let key = depot.register(
                key: Key.from("theme"),
                coder: .data(String.self),
            )

            #expect(try depot.get(valueFor: key, default: "system") == "system")

            try depot.set(value: "dark", for: key)
            #expect(try depot.get(valueFor: key, default: "system") == "dark")
        }
    }

    // MARK: - Async Depot.get(valueFor:default:)

    @Suite
    struct AsyncDefaultValue {
        @Test("returns stored value when it exists")
        func returnsStoredValue() async throws {
            let url = try DepotConfiguration.directoryURL(
                in: .temporary,
                name: "AsyncDefaultValue-stored-\(UUID().uuidString)",
            )
            defer { try? FileManager.default.removeItem(at: url) }

            let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
            let key = depot.register(
                key: Key.from("name"),
                coder: .data(String.self),
            )

            try await depot.set(value: "Bob", for: key)

            let result = try await depot.get(valueFor: key, default: "Guest")
            #expect(result == "Bob")
        }

        @Test("returns default value when no value exists")
        func returnsDefaultWhenNil() async throws {
            let url = try DepotConfiguration.directoryURL(
                in: .temporary,
                name: "AsyncDefaultValue-nil-\(UUID().uuidString)",
            )
            defer { try? FileManager.default.removeItem(at: url) }

            let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
            let key = depot.register(
                key: Key.from("name"),
                coder: .data(String.self),
            )

            let result = try await depot.get(valueFor: key, default: "Guest")
            #expect(result == "Guest")
        }
    }
}
