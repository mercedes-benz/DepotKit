// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

private final class EncryptionTestConfiguration {
    let depotURL: URL

    init() {
        depotURL = try! DepotConfiguration.directoryURL(
            in: .caches,
            name: "EncryptionTests-\(UUID().uuidString)",
        )
    }

    deinit {
        let depotURL = depotURL

        Task { @concurrent in
            do {
                try FileManager.default.removeItem(at: depotURL)
            } catch {
                // ignore
            }
        }
    }
}

@Suite
struct DepotEncryptionTests {
    @Test("throws if encryption key doesn't match")
    func throwsIfEncryptionKeyMismatch() throws {
        let testConfiguration = EncryptionTestConfiguration()

        let encryptionConfigurationA = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
        let encryptionConfigurationB = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())

        var depot = Depot(
            configuration: .init(
                directoryURL: testConfiguration.depotURL,
                encryption: encryptionConfigurationA,
                memoryCache: .disabled
            )
        )
        #expect(throws: Never.self) {
            try depot.verifyIntegrity()
        }

        depot = Depot(
            configuration: .init(
                directoryURL: testConfiguration.depotURL,
                encryption: encryptionConfigurationA,
                memoryCache: .disabled
            )
        )
        #expect(throws: Never.self) {
            try depot.verifyIntegrity()
        }

        depot = Depot(
            configuration: .init(
                directoryURL: testConfiguration.depotURL,
                encryption: encryptionConfigurationB,
                memoryCache: .disabled
            )
        )
        #expect(throws: (any Error).self) {
            try depot.verifyIntegrity()
        }
    }

    @Test("encrypted depot reads and writes correctly")
    func encryptedDepotReadsAndWrites() throws {
        let testConfiguration = EncryptionTestConfiguration()

        let encryptionConfiguration = try EncryptionConfiguration(
            cipher: .aesGCM,
            hashFunction: .sha256,
            key: EncryptionConfiguration.generateKey(),
        )

        let depot = Depot(
            configuration: .init(
                directoryURL: testConfiguration.depotURL,
                encryption: encryptionConfiguration,
                memoryCache: .disabled
            )
        )
        let key = depot.register(key: Key.from("secret" / "value"), coder: .data(String.self))

        try depot.set(value: "top-secret", for: key)
        #expect(try depot.get(valueFor: key) == "top-secret")
    }

    @Test("encrypted depot persists across instances with same key")
    func encryptedDepotPersistsAcrossInstances() throws {
        let testConfiguration = EncryptionTestConfiguration()

        let encryptionConfiguration = try EncryptionConfiguration(
            cipher: .aesGCM,
            hashFunction: .sha256,
            key: EncryptionConfiguration.generateKey(),
        )

        var depot = Depot(
            configuration: .init(
                directoryURL: testConfiguration.depotURL,
                encryption: encryptionConfiguration,
                memoryCache: .disabled
            )
        )
        var key = depot.register(key: Key.from("persistent"), coder: .data(String.self))
        try depot.set(value: "survives-restart", for: key)

        depot = Depot(
            configuration: .init(
                directoryURL: testConfiguration.depotURL,
                encryption: encryptionConfiguration,
                memoryCache: .disabled
            )
        )
        key = depot.register(key: Key.from("persistent"), coder: .data(String.self))
        #expect(try depot.get(valueFor: key) == "survives-restart")
    }
}
