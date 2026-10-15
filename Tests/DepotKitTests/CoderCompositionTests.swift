// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct CoderCompositionTests {
    @Test("json + compressed round-trips")
    func jsonCompressed() throws {
        struct Model: Codable, Equatable {
            let name: String
            let count: Int
        }
        let coder: AnyCoder<Model> = .json().compressed()

        let value = Model(name: "test", count: 42)
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("json + encrypted round-trips")
    func jsonEncrypted() throws {
        let config = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
        let coder: AnyCoder<String> = .json().encrypted(using: config)

        let value = "encrypted json string"
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("json + versioned round-trips")
    func jsonVersioned() throws {
        let coder: AnyCoder<String> = .json().versioned(version: 1) { _, _ in nil }

        let value = "versioned"
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("full chain: json + compressed + encrypted")
    func fullChain() throws {
        struct Model: Codable, Equatable {
            let id: Int
            let payload: String
        }

        let config = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
        let coder: AnyCoder<Model> = .json()
            .compressed(using: .lzfse)
            .encrypted(using: config)

        let value = Model(id: 99, payload: String(repeating: "data", count: 100))
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("full chain detects tampering via encryption MAC")
    func fullChainTampering() throws {
        let config = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
        let coder: AnyCoder<String> = .data()
            .compressed()
            .encrypted(using: config)

        var encoded = try coder.encode("sensitive")
        encoded[encoded.count / 2] ^= 0xFF

        #expect(throws: (any Error).self) {
            _ = try coder.decode(encoded)
        }
    }

    @Test("data + compressed round-trips")
    func dataCompressed() throws {
        let coder: AnyCoder<Data> = .data().compressed(using: .lz4)

        let value = Data(repeating: 0xAB, count: 1000)
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("versioned + encrypted round-trips")
    func versionedEncrypted() throws {
        let config = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
        let coder: AnyCoder<String> = .data()
            .versioned(version: 3) { _, _ in nil }
            .encrypted(using: config)

        let value = "versioned and encrypted"
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }
}
