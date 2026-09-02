// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct EncryptedCoderTests {
    @Suite
    struct EncryptionConfigurationTests {
        @Test("keySize is 512 bits")
        func keySize() {
            #expect(EncryptionConfiguration.keySize == 512)
        }

        @Test("generateKey produces 64 bytes")
        func generateKeySize() {
            let key = EncryptionConfiguration.generateKey()
            #expect(key.count == 64)
        }

        @Test("generateKey produces unique keys")
        func generateKeyUnique() {
            let keys = (0..<10).map { _ in EncryptionConfiguration.generateKey() }
            let unique = Set(keys)
            #expect(unique.count == 10)
        }

        @Test("splits key into cipher and auth halves")
        func keySplit() throws {
            let key = EncryptionConfiguration.generateKey()
            let config = try EncryptionConfiguration(key: key)

            #expect(config.cipherKey.bitCount == 256)
            #expect(config.authenticationKey.bitCount == 256)
            #expect(config.cipherKey != config.authenticationKey)
        }

        @Test("throws on key too short")
        func keyTooShort() {
            let shortKey = Data(repeating: 0xAA, count: 32)
            #expect(throws: EncryptedCoderError.invalidEncryptionKey) {
                _ = try EncryptionConfiguration(key: shortKey)
            }
        }

        @Test("throws on key too long")
        func keyTooLong() {
            let longKey = Data(repeating: 0xBB, count: 128)
            #expect(throws: EncryptedCoderError.invalidEncryptionKey) {
                _ = try EncryptionConfiguration(key: longKey)
            }
        }

        @Test("throws on empty key")
        func emptyKey() {
            #expect(throws: EncryptedCoderError.invalidEncryptionKey) {
                _ = try EncryptionConfiguration(key: Data())
            }
        }
    }

    @Suite
    struct RoundTrip {
        static let configurations: [EncryptionConfiguration] = {
            [
                try! EncryptionConfiguration(
                    cipher: .aesGCM,
                    hashFunction: .sha256,
                    key: EncryptionConfiguration.generateKey()
                ),
                try! EncryptionConfiguration(
                    cipher: .aesGCM,
                    hashFunction: .sha384,
                    key: EncryptionConfiguration.generateKey()
                ),
                try! EncryptionConfiguration(
                    cipher: .aesGCM,
                    hashFunction: .sha512,
                    key: EncryptionConfiguration.generateKey()
                ),
                try! EncryptionConfiguration(
                    cipher: .chaChaPoly,
                    hashFunction: .sha256,
                    key: EncryptionConfiguration.generateKey()
                ),
                try! EncryptionConfiguration(
                    cipher: .chaChaPoly,
                    hashFunction: .sha384,
                    key: EncryptionConfiguration.generateKey()
                ),
                try! EncryptionConfiguration(
                    cipher: .chaChaPoly,
                    hashFunction: .sha512,
                    key: EncryptionConfiguration.generateKey()
                ),
            ]
        }()

        @Test("round-trips all cipher/hash combinations", arguments: RoundTrip.configurations)
        func roundTrips(config: EncryptionConfiguration) throws {
            let coder: AnyCoder<String> = .data().encrypted(using: config)

            let values = ["", "hello", "😀🙋🏼‍♂️", String(repeating: "x", count: 5000)]
            for value in values {
                let encoded = try coder.encode(value)
                let decoded = try coder.decode(encoded)
                #expect(decoded == value)
            }
        }

        @Test("ciphertext differs from plaintext")
        func ciphertextDiffers() throws {
            let config = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
            let coder: AnyCoder<String> = .data().encrypted(using: config)

            let plaintext = "secret message"
            let encrypted = try coder.encode(plaintext)
            #expect(!encrypted.contains(Data(plaintext.utf8)))
        }

        @Test("same plaintext produces different ciphertext (nonce)")
        func nonceVariation() throws {
            let config = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
            let coder: AnyCoder<String> = .data().encrypted(using: config)

            let a = try coder.encode("same")
            let b = try coder.encode("same")
            #expect(a != b)
        }
    }

    @Suite
    struct Tampering {
        @Test("detects tampered HMAC")
        func tamperedHMAC() throws {
            let config = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
            let coder: AnyCoder<String> = .data().encrypted(using: config)

            var encoded = try coder.encode("secret")
            encoded[0] ^= 0xFF

            #expect(throws: EncryptedCoderError.invalidAuthenticationCode) {
                _ = try coder.decode(encoded)
            }
        }

        @Test("detects tampered ciphertext")
        func tamperedCiphertext() throws {
            let config = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
            let coder: AnyCoder<String> = .data().encrypted(using: config)

            var encoded = try coder.encode("secret")
            encoded[encoded.count - 1] ^= 0xFF

            #expect(throws: EncryptedCoderError.invalidAuthenticationCode) {
                _ = try coder.decode(encoded)
            }
        }

        @Test("throws on truncated data (shorter than digest)")
        func truncatedData() throws {
            let config = try EncryptionConfiguration(hashFunction: .sha256, key: EncryptionConfiguration.generateKey())
            let coder: AnyCoder<String> = .data().encrypted(using: config)

            let tooShort = Data(repeating: 0x00, count: 31)
            #expect(throws: EncryptedCoderError.invalidAuthenticationCode) {
                _ = try coder.decode(tooShort)
            }
        }

        @Test("wrong key cannot decrypt")
        func wrongKey() throws {
            let config1 = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
            let config2 = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())

            let coder1: AnyCoder<String> = .data().encrypted(using: config1)
            let coder2: AnyCoder<String> = .data().encrypted(using: config2)

            let encrypted = try coder1.encode("secret")

            #expect(throws: EncryptedCoderError.self) {
                _ = try coder2.decode(encrypted)
            }
        }
    }
}
