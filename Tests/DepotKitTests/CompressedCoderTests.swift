// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct CompressedCoderTests {
    @Test(
        "round-trips with all algorithms",
        arguments: [
            CompressionAlgorithm.zlib,
            CompressionAlgorithm.lzfse,
            CompressionAlgorithm.lz4,
            CompressionAlgorithm.lzma,
        ]
    )
    func roundTripsAllAlgorithms(algorithm: CompressionAlgorithm) throws {
        let coder: AnyCoder<String> = .data().compressed(using: algorithm)

        let values = [
            "hello",
            "world",
            "😀🙋🏼‍♂️",
            String(repeating: "abcdefgh", count: 1000),
        ]

        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("defaults to zlib")
    func defaultsToZlib() throws {
        let coder: AnyCoder<String> = .data().compressed()
        let value = String(repeating: "test", count: 100)
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("compresses repetitive data effectively")
    func compresses() throws {
        let baseCoder: AnyCoder<String> = .data()
        let value = String(repeating: "a", count: 50_000)
        let uncompressed = try baseCoder.encode(value)

        for algorithm: CompressionAlgorithm in [.zlib, .lzfse, .lz4, .lzma] {
            let compressedCoder = baseCoder.compressed(using: algorithm)
            let compressed = try compressedCoder.encode(value)
            #expect(compressed.count < uncompressed.count)
        }
    }

    @Test("throws decompressionFailed on garbage data")
    func throwsOnGarbageData() {
        let coder: AnyCoder<String> = .data().compressed(using: .zlib)
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])

        #expect(throws: CompressedCoderError.self) {
            _ = try coder.decode(garbage)
        }
    }

    @Test("throws decodingFailed when decompressed data doesn't match inner coder")
    func throwsDecodingFailed() throws {
        struct Strict: LosslessDataConvertible, Sendable {
            var dataRepresentation: Data? { Data([0x01]) }
            init?(dataRepresentation: Data) {
                guard dataRepresentation == Data([0x01]) else { return nil }
            }

            init() {}
        }

        let innerCoder: AnyCoder<Strict> = .data()
        let compressedCoder = innerCoder.compressed(using: .zlib)

        let validEncoded = try compressedCoder.encode(Strict())
        #expect(throws: Never.self) { _ = try compressedCoder.decode(validEncoded) }

        let wrongInner: AnyCoder<String> = .data()
        let wrongCompressed = wrongInner.compressed(using: .zlib)
        let wrongData = try wrongCompressed.encode("wrong")

        #expect(throws: CompressedCoderError.self) {
            _ = try compressedCoder.decode(wrongData)
        }
    }

    @Test("different algorithms produce different output")
    func algorithmsProduceDifferentOutput() throws {
        let value = String(repeating: "hello world ", count: 500)
        let zlibData = try AnyCoder<String>.data().compressed(using: .zlib).encode(value)
        let lz4Data = try AnyCoder<String>.data().compressed(using: .lz4).encode(value)
        #expect(zlibData != lz4Data)
    }
}
