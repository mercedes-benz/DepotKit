// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct DepotErrorTests {
    // MARK: - Error Equality

    @Suite
    struct Equality {
        @Test("unregisteredKey errors with same keyPath are equal")
        func unregisteredKeyEquality() {
            let a = DepotError.unregisteredKey(keyPath: "user/settings")
            let b = DepotError.unregisteredKey(keyPath: "user/settings")
            #expect(a == b)
        }

        @Test("unregisteredKey errors with different keyPaths are not equal")
        func unregisteredKeyInequality() {
            let a = DepotError.unregisteredKey(keyPath: "user/settings")
            let b = DepotError.unregisteredKey(keyPath: "user/profile")
            #expect(a != b)
        }

        @Test("mismatchedTypes errors with same fields are equal")
        func mismatchedTypesEquality() {
            let a = DepotError.mismatchedTypes(keyPath: "k", expected: "String", actual: "Int")
            let b = DepotError.mismatchedTypes(keyPath: "k", expected: "String", actual: "Int")
            #expect(a == b)
        }

        @Test("reservedKey errors with same keyPath are equal")
        func reservedKeyEquality() {
            let a = DepotError.reservedKey(keyPath: ".internal")
            let b = DepotError.reservedKey(keyPath: ".internal")
            #expect(a == b)
        }
    }

    // MARK: - Contextual Key Paths in Errors

    @Suite
    struct ContextualKeyPaths {
        @Test("unregisteredKey includes the key path")
        func unregisteredKeyIncludesKeyPath() {
            let depot = Depot.temporary()
            let key = Key.from("user" / "settings", as: String.self)

            // Register the key so we can store a value, then try reading with wrong registration
            // Instead, just try to get a value that triggers coder lookup
            depot.register(key: Key.from("other"), coder: .data(String.self))

            // This depot has useCoders=true, so `set` for an unregistered key will fail
            do {
                try depot.set(value: "test", for: key)
                Issue.record("Expected unregisteredKey error")
            } catch {
                guard case let DepotError.unregisteredKey(keyPath) = error else {
                    Issue.record("Wrong error type: \(error)")
                    return
                }
                #expect(keyPath == "user/settings")
            }
        }

        @Test("mismatchedTypes includes key path, expected, and actual types")
        func mismatchedTypesIncludesContext() {
            let depot = Depot.temporary()
            depot.register(
                key: Key.from("entity" / "status"),
                coder: .data(String.self),
            )

            // Store a value so get can trigger coder lookup
            try? depot.set(value: "active", for: Key.from("entity" / "status", as: String.self))

            let wrongKey = Key.from("entity" / "status", as: Int.self)

            do {
                _ = try depot.get(valueFor: wrongKey)
                Issue.record("Expected mismatchedTypes error")
            } catch {
                guard case let DepotError.mismatchedTypes(keyPath, expected, actual) = error else {
                    Issue.record("Wrong error type: \(error)")
                    return
                }
                #expect(keyPath == "entity/status")
                #expect(expected == "Int")
                #expect(actual == "String")
            }
        }

        @Test("unregisteredKey error for wildcard key includes wildcard path")
        func unregisteredWildcardKey() {
            let depot = Depot.temporary()

            // Store a matching value first so get(valuesFor:) triggers coder lookup
            depot.register(key: Key.from("other"), coder: .data(String.self))

            do {
                try depot.set(value: "test", for: Key.from("unknown" / "A", as: String.self))
                Issue.record("Expected unregisteredKey error")
            } catch {
                guard case let DepotError.unregisteredKey(keyPath) = error else {
                    Issue.record("Wrong error type: \(error)")
                    return
                }
                #expect(keyPath == "unknown/A")
            }
        }
    }

    // MARK: - LocalizedError Descriptions with Hints

    @Suite
    struct ErrorDescriptions {
        @Test("readOnlyDepot includes hint about initialization")
        func readOnlyDepotHint() {
            let error = DepotError.readOnlyDepot
            let description = error.errorDescription ?? ""
            #expect(description.contains("read-only"))
            #expect(description.contains("Hint:"))
        }

        @Test("metadataNotFound includes hint about verifyIntegrity")
        func metadataNotFoundHint() {
            let error = DepotError.metadataNotFound
            let description = error.errorDescription ?? ""
            #expect(description.contains("metadata"))
            #expect(description.contains("Hint:"))
            #expect(description.contains("verifyIntegrity"))
        }

        @Test("unregisteredKey includes key path and register hint")
        func unregisteredKeyHint() {
            let error = DepotError.unregisteredKey(keyPath: "user/settings")
            let description = error.errorDescription ?? ""
            #expect(description.contains("user/settings"))
            #expect(description.contains("Hint:"))
            #expect(description.contains("register"))
        }

        @Test("reservedKey includes key path and hint")
        func reservedKeyHint() {
            let error = DepotError.reservedKey(keyPath: ".FS_META")
            let description = error.errorDescription ?? ""
            #expect(description.contains(".FS_META"))
            #expect(description.contains("Hint:"))
            #expect(description.contains("internal prefix"))
        }

        @Test("mismatchedTypes includes key path, types, and hint")
        func mismatchedTypesHint() {
            let error = DepotError.mismatchedTypes(
                keyPath: "entity/status",
                expected: "Date",
                actual: "String",
            )
            let description = error.errorDescription ?? ""
            #expect(description.contains("entity/status"))
            #expect(description.contains("Date"))
            #expect(description.contains("String"))
            #expect(description.contains("Hint:"))
        }

        @Test("functionNotAvailable includes hint")
        func functionNotAvailableHint() {
            let error = DepotError.functionNotAvailable
            let description = error.errorDescription ?? ""
            #expect(description.contains("not available"))
            #expect(description.contains("Hint:"))
        }
    }

    // MARK: - Error Propagation Through Depot Operations

    @Suite
    struct ErrorPropagation {
        @Test("set on read-only depot throws readOnlyDepot")
        func readOnlyDepotThrows() {
            let depot = Depot(
                configuration: .init(
                    directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                    readOnly: true,
                    memoryCache: .disabled
                )
            )
            let key = depot.register(
                key: Key.from("test"),
                coder: .data(String.self),
            )

            #expect(throws: DepotError.readOnlyDepot) {
                try depot.set(value: "value", for: key)
            }
        }

        @Test("remove on read-only depot throws readOnlyDepot")
        func readOnlyRemoveThrows() {
            let depot = Depot(
                configuration: .init(
                    directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                    readOnly: true,
                    memoryCache: .disabled
                )
            )
            let key = depot.register(
                key: Key.from("test"),
                coder: .data(String.self),
            )

            #expect(throws: DepotError.readOnlyDepot) {
                try depot.remove(valuesFor: key)
            }
        }

        @Test("Depot unregistered key error includes correct path")
        func depotUnregisteredKeyPath() throws {
            let url = try DepotConfiguration.directoryURL(
                in: .temporary,
                name: "DepotErrorTests-\(UUID().uuidString)",
            )
            defer { try? FileManager.default.removeItem(at: url) }

            let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
            let key = Key.from("account" / "profile", as: String.self)

            // Write a file at the key's path so Depot finds it and triggers coder lookup
            let fileURL = try depot.fileURL(for: Key.from("account" / "profile"))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try "bogus".data(using: .utf8)!.write(to: fileURL)

            do {
                _ = try depot.get(valueFor: key)
                Issue.record("Expected unregisteredKey error")
            } catch {
                guard case let DepotError.unregisteredKey(keyPath) = error else {
                    Issue.record("Wrong error type: \(error)")
                    return
                }
                #expect(keyPath == "account/profile")
            }
        }
    }
}
