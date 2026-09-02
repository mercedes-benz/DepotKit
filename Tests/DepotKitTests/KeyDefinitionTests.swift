// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct KeyDefinitionTests {
    // MARK: - KeyDefinition

    @Suite
    struct Distinct {
        @Test("creates definition from key path expression")
        func createsFromPath() {
            let definition = KeyDefinition<String>(
                path: "user" / "username",
                coder: .json(),
            )

            #expect(definition.key == Key.from("user" / "username"))
        }

        @Test("creates definition from distinct key")
        func createsFromKey() {
            let distinctKey = Key.from("user" / "settings")
            let definition = KeyDefinition<String>(
                key: distinctKey,
                coder: .json(),
            )

            #expect(definition.key == distinctKey)
        }

        @Test("registers with depot and returns typed distinct key")
        func registersWithDepot() throws {
            let depot = Depot.temporary()
            let definition = KeyDefinition<String>(
                path: "user" / "name",
                coder: .json(),
            )

            let key = depot.register(definition)
            try depot.set(value: "Alice", for: key)
            let value = try depot.get(valueFor: key)

            #expect(value == "Alice")
        }

        @Test("supports static property pattern")
        func staticPropertyPattern() throws {
            enum Keys {
                static let username = KeyDefinition<String>(
                    path: "user" / "username",
                    coder: .json(),
                )
                static let age = KeyDefinition<Int>(
                    path: "user" / "age",
                    coder: .json(),
                )
            }

            let depot = Depot.temporary()

            let usernameKey = depot.register(Keys.username)
            let ageKey = depot.register(Keys.age)

            try depot.set(value: "Bob", for: usernameKey)
            try depot.set(value: 30, for: ageKey)

            #expect(try depot.get(valueFor: usernameKey) == "Bob")
            #expect(try depot.get(valueFor: ageKey) == 30)
        }

        @Test("register is discardable")
        func registerIsDiscardable() {
            let depot = Depot.temporary()
            let definition = KeyDefinition<String>(
                path: "test",
                coder: .json(),
            )

            depot.register(definition)

            #expect(depot.keys.contains(definition.key.key))
        }

        @Test("supports coder chaining with dot-syntax")
        func coderChaining() throws {
            let depot = Depot.temporary()
            let definition = KeyDefinition<String>(
                path: "user" / "data",
                coder: .json().compressed(),
            )

            let key = depot.register(definition)
            try depot.set(value: "hello", for: key)
            #expect(try depot.get(valueFor: key) == "hello")
        }

        @Test("supports coder chaining with type parameter")
        func coderChainingWithType() throws {
            let depot = Depot.temporary()

            let key = depot.register(
                key: Key.from("user" / "compressed"),
                coder: .json(String.self).compressed(),
            )

            try depot.set(value: "world", for: key)
            #expect(try depot.get(valueFor: key) == "world")
        }
    }

    // MARK: - PatternKeyDefinition

    @Suite
    struct Wildcard {
        @Test("creates definition from pattern key path expression")
        func createsFromPath() {
            let definition = PatternKeyDefinition<String>(
                path: "users" / .wildcard / "settings",
                coder: .json(),
            )

            #expect(definition.key == Key.from("users" / .wildcard / "settings"))
        }

        @Test("creates definition from key")
        func createsFromKey() {
            let key = Key.from("items" / .wildcard)
            let definition = PatternKeyDefinition<String>(
                key: key,
                coder: .json(),
            )

            #expect(definition.key == key)
        }

        @Test("registers with depot and returns typed key")
        func registersWithDepot() throws {
            let depot = Depot.temporary()
            let wildcardDefinition = PatternKeyDefinition<String>(
                path: "users" / .wildcard / "name",
                coder: .json(),
            )

            let wildcardKey = depot.register(wildcardDefinition)

            // Register and set individual distinct keys that match the wildcard
            let aliceKey: TypedDistinctKey<String> = depot.register(
                keyPath: "users" / "alice" / "name",
                coder: .json(),
            )
            let bobKey: TypedDistinctKey<String> = depot.register(
                keyPath: "users" / "bob" / "name",
                coder: .json(),
            )

            try depot.set(value: "Alice", for: aliceKey)
            try depot.set(value: "Bob", for: bobKey)

            let allNames = try depot.get(valuesFor: wildcardKey)
            #expect(Set(allNames) == Set(["Alice", "Bob"]))
        }
    }
}
