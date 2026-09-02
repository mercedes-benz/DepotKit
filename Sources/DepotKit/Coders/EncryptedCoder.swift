// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import CryptoKit
import Foundation

extension AnyCoder {
    /// Wraps this coder with encryption.
    ///
    /// ```swift
    /// depot.register(key: ..., coder: .json().encrypted(using: encryptionConfig))
    /// ```
    public func encrypted(using configuration: EncryptionConfiguration) -> AnyCoder<Value> {
        EncryptedCoder(self, configuration: configuration).eraseToAnyCoder()
    }
}

/// Errors related to ``Coder/encrypted(using:)``.
public enum EncryptedCoderError: Error {
    /// The key must be exactly 512 bits (64 bytes) long.
    case invalidEncryptionKey

    /// Decryption failed because the MAC is invalid.
    case invalidAuthenticationCode

    /// Encoding with the wrapped coder failed.
    case encodingFailed(underlyingError: Error)

    /// Encryption failed due to an underlying error.
    case encryptionFailed(underlyingError: Error)

    /// Decoding with the wrapped coder failed.
    case decodingFailed(underlyingError: Error)

    /// Decryption failed due to an underlying error.
    case decryptionFailed(underlyingError: Error)
}

extension EncryptedCoderError: Equatable {
    public static func == (lhs: EncryptedCoderError, rhs: EncryptedCoderError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidEncryptionKey, .invalidEncryptionKey):
            true
        case (.invalidAuthenticationCode, .invalidAuthenticationCode):
            true
        case (.encodingFailed, .encodingFailed),
            (.encryptionFailed, .encryptionFailed),
            (.decodingFailed, .decodingFailed),
            (.decryptionFailed, .decryptionFailed):
            true
        default:
            false
        }
    }
}

extension EncryptedCoderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEncryptionKey:
            "The encryption key must be exactly 512 bits (64 bytes)."
        case .invalidAuthenticationCode:
            "The authentication code is invalid — the data may have been tampered with."
        case let .encodingFailed(error):
            "Encoding failed: \(error.localizedDescription)"
        case let .encryptionFailed(error):
            "Encryption failed: \(error.localizedDescription)"
        case let .decodingFailed(error):
            "Decoding failed: \(error.localizedDescription)"
        case let .decryptionFailed(error):
            "Decryption failed: \(error.localizedDescription)"
        }
    }
}

/// Configuration for an encrypted coder.
///
/// `EncryptionConfiguration` accepts raw key material directly. The key must be
/// exactly 512 bits (64 bytes) of high-entropy data — for example, output from a
/// cryptographically secure random number generator.
///
/// **Do not pass passphrases or low-entropy strings as key material.** If you need
/// to derive a key from a passphrase, use a proper key derivation function such as
/// HKDF (`CryptoKit.HKDF`) or PBKDF2 (`CCKeyDerivationPBKDF`) to produce the
/// required 64 bytes before creating this configuration.
///
/// Use ``generateKey()`` to create a random key suitable for this configuration.
/// Store the generated key securely (e.g. in the Keychain) and reuse it across
/// app launches.
public struct EncryptionConfiguration: Sendable {
    /// The cipher to use.
    public enum Cipher: Sendable {
        /// See `AES.GCM` in *CryptoKit*.
        case aesGCM

        /// See `ChaChaPoly` in *CryptoKit*.
        case chaChaPoly
    }

    /// The hash function used for the additional HMAC authentication layer.
    ///
    /// Both AES-GCM and ChaChaPoly are AEAD ciphers that already authenticate
    /// ciphertext via their built-in tags. The extra HMAC provides defense-in-depth:
    /// an independent authentication check that does not share code paths or
    /// assumptions with the cipher's tag verification. This adds minor computational
    /// overhead but guards against implementation-level issues in any single
    /// cryptographic primitive.
    public enum HashFunction: Sendable {
        /// SHA2-256 hash function.
        case sha256

        /// SHA2-384 hash function.
        case sha384

        /// SHA2-512 hash function.
        case sha512

        /// Length of the digest in bytes.
        public var digestLength: Int {
            switch self {
            case .sha256:
                SHA256Digest.byteCount
            case .sha384:
                SHA384Digest.byteCount
            case .sha512:
                SHA512Digest.byteCount
            }
        }

        /// Computes the HMAC authentication code for the given data.
        func authenticationCode(for data: some DataProtocol, using key: SymmetricKey) -> Data {
            switch self {
            case .sha256:
                HMAC<CryptoKit.SHA256>.authenticationCode(for: data, using: key)
                    .withUnsafeBytes { Data($0) }
            case .sha384:
                HMAC<CryptoKit.SHA384>.authenticationCode(for: data, using: key)
                    .withUnsafeBytes { Data($0) }
            case .sha512:
                HMAC<CryptoKit.SHA512>.authenticationCode(for: data, using: key)
                    .withUnsafeBytes { Data($0) }
            }
        }

        /// Validates the HMAC authentication code for the given data.
        func isValidAuthenticationCode(
            _ code: Data,
            authenticating data: some DataProtocol,
            using key: SymmetricKey,
        ) -> Bool {
            switch self {
            case .sha256:
                HMAC<CryptoKit.SHA256>.isValidAuthenticationCode(code, authenticating: data, using: key)
            case .sha384:
                HMAC<CryptoKit.SHA384>.isValidAuthenticationCode(code, authenticating: data, using: key)
            case .sha512:
                HMAC<CryptoKit.SHA512>.isValidAuthenticationCode(code, authenticating: data, using: key)
            }
        }
    }

    /// The cipher to use.
    public let cipher: Cipher

    /// The hash function for the defense-in-depth HMAC layer (see ``HashFunction``).
    public let hashFunction: HashFunction

    /// The symmetric key used for the cipher (256 bits).
    let cipherKey: SymmetricKey

    /// The symmetric key used for the MAC (256 bits).
    let authenticationKey: SymmetricKey

    /// Designated initializer.
    ///
    /// Obviously, you have to make sure that you use the same key across app launches.
    /// Ideally, you generate a key once and then save it to the *Keychain*.
    ///
    /// - Parameters:
    ///   - cipher: The cipher to use.
    ///   - hashFunction: The hash function to use.
    ///   - key: The encryption key to use.
    ///
    /// - Throws: ``EncryptedCoderError/invalidEncryptionKey`` if `key` is not of the correct size.
    ///
    /// > Warning: The key must be exactly 512 bits (64 bytes) long!
    ///
    /// > Important: The key must be high-entropy data (e.g. from ``generateKey()``
    /// > or a KDF). Do not use passphrases directly.
    public init(
        cipher: Cipher = .chaChaPoly,
        hashFunction: HashFunction = .sha256,
        key: Data,
    ) throws(EncryptedCoderError) {
        guard key.count == 64 else {
            throw EncryptedCoderError.invalidEncryptionKey
        }

        self.cipher = cipher
        self.hashFunction = hashFunction
        cipherKey = SymmetricKey(data: key[key.startIndex..<key.startIndex + 32])
        authenticationKey = SymmetricKey(data: key[key.startIndex + 32..<key.startIndex + 64])
    }
}

extension EncryptionConfiguration {
    /// The total key size in bits.
    public static var keySize: Int {
        512
    }

    /// Generates a random 512 bits long key.
    ///
    /// - Returns: A randomly generated 512 bits long key.
    public static func generateKey() -> Data {
        let key = SymmetricKey(size: .init(bitCount: keySize))
        return key.withUnsafeBytes { Data($0) }
    }
}

// MARK: - EncryptedCoder

/// A coder that encrypts values using a symmetric-key cipher and
/// verifies integrity with an additional HMAC (encrypt-then-MAC composition).
///
/// Both AES-GCM and ChaChaPoly are AEAD ciphers that authenticate ciphertext
/// via their built-in tags. The extra HMAC provides defense-in-depth — an
/// independent authentication check that does not share code paths or
/// assumptions with the cipher's tag verification.
struct EncryptedCoder<Value: Sendable>: Coder {
    let coder: AnyCoder<Value>
    let configuration: EncryptionConfiguration

    private var cipherKey: SymmetricKey { configuration.cipherKey }
    private var authenticationKey: SymmetricKey { configuration.authenticationKey }

    init<C>(_ coder: C, configuration: EncryptionConfiguration) where C: Coder, C.Value == Value {
        self.coder = coder.eraseToAnyCoder()
        self.configuration = configuration
    }

    var coderDescription: String { "\(coder.coderDescription).encrypted(.\(configuration.cipher))" }

    func encode(_ value: Value) throws(EncryptedCoderError) -> Data {
        let data: Data
        do {
            data = try coder.encode(value)
        } catch {
            throw EncryptedCoderError.encodingFailed(underlyingError: error)
        }

        let encryptedData: Data
        do {
            switch configuration.cipher {
            case .aesGCM:
                let box = try AES.GCM.seal(data, using: cipherKey)
                guard let combined = box.combined else {
                    throw CryptoKitError.underlyingCoreCryptoError(error: 0)
                }

                encryptedData = combined
            case .chaChaPoly:
                let box = try ChaChaPoly.seal(data, using: cipherKey)
                encryptedData = box.combined
            }
        } catch {
            throw EncryptedCoderError.encryptionFailed(underlyingError: error)
        }

        let authenticationCode = configuration.hashFunction.authenticationCode(
            for: encryptedData,
            using: authenticationKey,
        )

        return authenticationCode + encryptedData
    }

    func decode(_ data: Data) throws(EncryptedCoderError) -> Value {
        let digestLength = configuration.hashFunction.digestLength
        guard data.count > digestLength else {
            LOG(
                level: .error,
                message: "EncryptedCoder: data too short for MAC (\(data.count) bytes, need >\(digestLength))"
            )
            throw EncryptedCoderError.invalidAuthenticationCode
        }

        let authenticationCode = Data(data.prefix(digestLength))
        let encryptedData = Data(data.dropFirst(digestLength))

        let isValidAuthenticationCode = configuration.hashFunction.isValidAuthenticationCode(
            authenticationCode,
            authenticating: encryptedData,
            using: authenticationKey,
        )

        guard isValidAuthenticationCode else {
            LOG(
                level: .error,
                message: "EncryptedCoder: MAC verification failed — data may be corrupted or key mismatch"
            )
            throw EncryptedCoderError.invalidAuthenticationCode
        }

        let decryptedData: Data
        do {
            switch configuration.cipher {
            case .aesGCM:
                let box = try AES.GCM.SealedBox(combined: encryptedData)
                decryptedData = try AES.GCM.open(box, using: cipherKey)
            case .chaChaPoly:
                let box = try ChaChaPoly.SealedBox(combined: encryptedData)
                decryptedData = try ChaChaPoly.open(box, using: cipherKey)
            }
        } catch {
            throw EncryptedCoderError.decryptionFailed(underlyingError: error)
        }

        do {
            return try coder.decode(decryptedData)
        } catch {
            throw EncryptedCoderError.decodingFailed(underlyingError: error)
        }
    }

}
