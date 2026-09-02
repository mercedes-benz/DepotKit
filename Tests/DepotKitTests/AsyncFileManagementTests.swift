// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct AsyncFileManagementTests {
    @Test("async verifyIntegrity succeeds on valid depot")
    func verifyIntegritySuccess() async throws {
        let depot = Depot.temporary()
        try await depot.verifyIntegrity()
    }

    @Test("async verifyIntegrity is no-op for memory depot")
    func verifyIntegrityMemoryOnly() async throws {
        let depot = Depot(label: "mem")
        try await depot.verifyIntegrity()
    }

    @Test("async reset clears all values")
    func resetClearsValues() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try await depot.set(value: "hello", for: key)
        try await depot.reset()
        let result: String? = try await depot.get(valueFor: key)
        #expect(result == nil)
    }

    @Test("async reset on read-only depot throws")
    func resetReadOnlyThrows() async throws {
        let depot = Depot(
            configuration: .init(
                directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                readOnly: true
            )
        )
        await #expect(throws: DepotError.self) {
            try await depot.reset()
        }
    }

    @Test("async clearCache is a no-op without cache")
    func clearCacheNoop() async throws {
        let depot = Depot.temporary(memoryCache: .disabled)
        await depot.clearCache()
    }

    @Test("async clearCache evicts cached values")
    func clearCacheEvicts() async throws {
        let depot = Depot.temporary(memoryCache: .default)
        let key = depot.register(keyPath: "cached", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 42, for: key)
        // Read to populate cache
        _ = try await depot.get(valueFor: key)
        await depot.clearCache()
        // Should still work (reads from disk)
        let result = try await depot.get(valueFor: key)
        #expect(result == 42)
    }

    @Test("async checkForExternalChanges is no-op without multi-process")
    func checkExternalChangesNoop() async throws {
        let depot = Depot.temporary()
        try await depot.checkForExternalChanges()
    }

    @Test("async verifyIntegrity detects wrong encryption key")
    func verifyIntegrityWrongKey() async throws {
        let key1 = EncryptionConfiguration.generateKey()
        let config1 = try EncryptionConfiguration(key: key1)
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)

        // Create depot with key1
        let depot1 = Depot(configuration: .init(directoryURL: url, encryption: config1))
        let dataKey = depot1.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try await depot1.set(value: "test", for: dataKey)

        // Open same depot with different key
        let key2 = EncryptionConfiguration.generateKey()
        let config2 = try EncryptionConfiguration(key: key2)
        let depot2 = Depot(configuration: .init(directoryURL: url, encryption: config2))

        #expect(throws: (any Error).self) {
            try depot2.verifyIntegrity()
        }
    }
}
