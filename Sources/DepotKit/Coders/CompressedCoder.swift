// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

extension AnyCoder {
    /// Wraps this coder with compression.
    ///
    /// ```swift
    /// depot.register(key: Key.from("user" / "data"), coder: .json().compressed())
    /// ```
    public func compressed(using algorithm: CompressionAlgorithm = .zlib) -> AnyCoder<Value> {
        CompressedCoder(self, algorithm: algorithm).eraseToAnyCoder()
    }
}

/// Compression algorithms supported by ``AnyCoder/compressed(using:)``.
public enum CompressionAlgorithm: Sendable {
    /// ZLIB (Deflate) compression.
    case zlib

    /// LZFSE compression.
    case lzfse

    /// LZ4 compression.
    case lz4

    /// LZMA compression.
    case lzma

    fileprivate var foundationAlgorithm: NSData.CompressionAlgorithm {
        switch self {
        case .zlib:
            .zlib
        case .lzfse:
            .lzfse
        case .lz4:
            .lz4
        case .lzma:
            .lzma
        }
    }
}

/// Errors related to ``AnyCoder/compressed(using:)``.
public enum CompressedCoderError: Error {
    /// Encoding with the wrapped coder failed.
    case encodingFailed(underlyingError: Error)

    /// Compression failed due to an underlying error.
    case compressionFailed(underlyingError: Error)

    /// Decompression failed due to an underlying error.
    case decompressionFailed(underlyingError: Error)

    /// Decoding with the wrapped coder failed.
    case decodingFailed(underlyingError: Error)
}

extension CompressedCoderError: Equatable {
    public static func == (lhs: CompressedCoderError, rhs: CompressedCoderError) -> Bool {
        switch (lhs, rhs) {
        case (.encodingFailed, .encodingFailed),
            (.compressionFailed, .compressionFailed),
            (.decompressionFailed, .decompressionFailed),
            (.decodingFailed, .decodingFailed):
            true
        default:
            false
        }
    }
}

extension CompressedCoderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .encodingFailed(error):
            "Encoding failed: \(error.localizedDescription)"
        case let .compressionFailed(error):
            "Compression failed: \(error.localizedDescription)"
        case let .decompressionFailed(error):
            "Decompression failed: \(error.localizedDescription)"
        case let .decodingFailed(error):
            "Decoding failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - CompressedCoder

/// A coder that compresses encoded data using a specified algorithm.
struct CompressedCoder<Value: Sendable>: Coder {
    let coder: AnyCoder<Value>
    let algorithm: CompressionAlgorithm

    init<C>(_ coder: C, algorithm: CompressionAlgorithm) where C: Coder, C.Value == Value {
        self.coder = coder.eraseToAnyCoder()
        self.algorithm = algorithm
    }

    var coderDescription: String { "\(coder.coderDescription).compressed(.\(algorithm))" }

    func encode(_ value: Value) throws(CompressedCoderError) -> Data {
        let data: Data
        do {
            data = try coder.encode(value)
        } catch {
            throw CompressedCoderError.encodingFailed(underlyingError: error)
        }

        do {
            return try (data as NSData).compressed(using: algorithm.foundationAlgorithm) as Data
        } catch {
            throw CompressedCoderError.compressionFailed(underlyingError: error)
        }
    }

    func decode(_ data: Data) throws(CompressedCoderError) -> Value {
        let decompressedData: Data
        do {
            decompressedData = try (data as NSData).decompressed(using: algorithm.foundationAlgorithm) as Data
        } catch {
            throw CompressedCoderError.decompressionFailed(underlyingError: error)
        }

        do {
            return try coder.decode(decompressedData)
        } catch {
            throw CompressedCoderError.decodingFailed(underlyingError: error)
        }
    }

}
