// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct CompressedCoderAdditionalTests {
    @Test("lz4 roundtrip with small data")
    func lz4SmallData() throws {
        let coder: AnyCoder<Data> = .data().compressed(using: .lz4)
        let value = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("lzfse roundtrip with JSON content")
    func lzfseJson() throws {
        let coder: AnyCoder<[String: Int]> = .json().compressed(using: .lzfse)
        let value = ["alpha": 1, "beta": 2, "gamma": 3]
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("lzma roundtrip with plist content")
    func lzmaPlist() throws {
        let coder: AnyCoder<[String]> = .plist().compressed(using: .lzma)
        let value = (0..<100).map { "item_\($0)" }
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("zlib roundtrip with unicode content")
    func zlibUnicode() throws {
        let coder: AnyCoder<String> = .data().compressed(using: .zlib)
        let value = "Ünîcödé 🎉🚀 特殊字符 données spéciales"
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test(
        "corrupted data throws decompressionFailed for all algorithms",
        arguments: [
            CompressionAlgorithm.zlib,
            CompressionAlgorithm.lzfse,
            CompressionAlgorithm.lz4,
            CompressionAlgorithm.lzma,
        ]
    )
    func corruptedData(algorithm: CompressionAlgorithm) {
        let coder: AnyCoder<String> = .data().compressed(using: algorithm)
        let garbage = Data(repeating: 0xAB, count: 32)

        #expect(throws: CompressedCoderError.self) {
            _ = try coder.decode(garbage)
        }
    }

    @Test(
        "large data roundtrip (>1MB)",
        arguments: [
            CompressionAlgorithm.zlib,
            CompressionAlgorithm.lz4,
            CompressionAlgorithm.lzfse,
        ]
    )
    func largeData(algorithm: CompressionAlgorithm) throws {
        let coder: AnyCoder<Data> = .data().compressed(using: algorithm)
        let value = Data((0..<1_100_000).map { UInt8($0 % 256) })
        let encoded = try coder.encode(value)
        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("encoding failure propagates as encodingFailed")
    func encodingFailure() {
        struct AlwaysFails: LosslessDataConvertible, Sendable {
            var dataRepresentation: Data? { nil }
            init?(dataRepresentation _: Data) { nil }
            init() {}
        }

        let coder: AnyCoder<AlwaysFails> = .data().compressed(using: .zlib)
        #expect(throws: CompressedCoderError.self) {
            _ = try coder.encode(AlwaysFails())
        }
    }

    @Test("error descriptions are non-empty")
    func errorDescriptions() {
        let errors: [CompressedCoderError] = [
            .encodingFailed(underlyingError: DataCoderError.noData),
            .compressionFailed(underlyingError: DataCoderError.noData),
            .decompressionFailed(underlyingError: DataCoderError.noData),
            .decodingFailed(underlyingError: DataCoderError.noData),
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
}

// MARK: - Additional DataCoder Tests

@Suite
struct DataCoderAdditionalTests {
    @Test("roundtrips UInt values")
    func uintRoundTrip() throws {
        let coder: AnyCoder<UInt> = .data()
        let values: [UInt] = [0, 1, UInt.max, 42, 1_000_000]
        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("roundtrips Float values")
    func floatRoundTrip() throws {
        let coder: AnyCoder<Float> = .data()
        let values: [Float] = [0.0, 1.0, -1.0, .pi, .greatestFiniteMagnitude, .leastNonzeroMagnitude]
        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("roundtrips Double values")
    func doubleRoundTrip() throws {
        let coder: AnyCoder<Double> = .data()
        let values: [Double] = [0.0, 1.0, -1.0, .pi, .greatestFiniteMagnitude, .leastNonzeroMagnitude]
        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("roundtrips UUID values")
    func uuidRoundTrip() throws {
        let coder: AnyCoder<UUID> = .data()
        for _ in 0..<5 {
            let value = UUID()
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("roundtrips URL values")
    func urlRoundTrip() throws {
        let coder: AnyCoder<URL> = .data()
        let values: [URL] = [
            URL(string: "https://example.com")!,
            URL(string: "file:///tmp/file.txt")!,
            URL(string: "https://example.com/path?q=hello%20world&foo=bar#fragment")!,
            URL(string: "custom-scheme://host/path")!,
        ]
        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("roundtrips Date values")
    func dateRoundTrip() throws {
        let coder: AnyCoder<Date> = .data()
        let values: [Date] = [
            Date.distantPast,
            Date.distantFuture,
            Date(timeIntervalSinceReferenceDate: 0),
            Date(timeIntervalSince1970: 1_700_000_000),
        ]
        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("roundtrips Int8 values")
    func int8RoundTrip() throws {
        let coder: AnyCoder<Int8> = .data()
        let values: [Int8] = [0, 1, -1, .max, .min]
        for value in values {
            #expect(try coder.decode(coder.encode(value)) == value)
        }
    }

    @Test("roundtrips Int16 values")
    func int16RoundTrip() throws {
        let coder: AnyCoder<Int16> = .data()
        let values: [Int16] = [0, 1, -1, .max, .min, 1000]
        for value in values {
            #expect(try coder.decode(coder.encode(value)) == value)
        }
    }

    @Test("roundtrips Int32 values")
    func int32RoundTrip() throws {
        let coder: AnyCoder<Int32> = .data()
        let values: [Int32] = [0, 1, -1, .max, .min]
        for value in values {
            #expect(try coder.decode(coder.encode(value)) == value)
        }
    }

    @Test("roundtrips Int64 values")
    func int64RoundTrip() throws {
        let coder: AnyCoder<Int64> = .data()
        let values: [Int64] = [0, 1, -1, .max, .min]
        for value in values {
            #expect(try coder.decode(coder.encode(value)) == value)
        }
    }

    @Test("roundtrips UInt8 values")
    func uint8RoundTrip() throws {
        let coder: AnyCoder<UInt8> = .data()
        let values: [UInt8] = [0, 1, .max, 128]
        for value in values {
            #expect(try coder.decode(coder.encode(value)) == value)
        }
    }

    @Test("roundtrips UInt16 values")
    func uint16RoundTrip() throws {
        let coder: AnyCoder<UInt16> = .data()
        let values: [UInt16] = [0, 1, .max, 1000]
        for value in values {
            #expect(try coder.decode(coder.encode(value)) == value)
        }
    }

    @Test("roundtrips UInt32 values")
    func uint32RoundTrip() throws {
        let coder: AnyCoder<UInt32> = .data()
        let values: [UInt32] = [0, 1, .max]
        for value in values {
            #expect(try coder.decode(coder.encode(value)) == value)
        }
    }

    @Test("roundtrips UInt64 values")
    func uint64RoundTrip() throws {
        let coder: AnyCoder<UInt64> = .data()
        let values: [UInt64] = [0, 1, .max]
        for value in values {
            #expect(try coder.decode(coder.encode(value)) == value)
        }
    }

    @Test("Int decode fails with truncated data")
    func intDecodeTruncated() {
        let coder: AnyCoder<Int> = .data()
        let truncated = Data([0x01, 0x02])
        #expect(throws: DataCoderError.badData) {
            _ = try coder.decode(truncated)
        }
    }

    @Test("UUID decode fails with invalid string")
    func uuidDecodeInvalid() {
        let coder: AnyCoder<UUID> = .data()
        let invalid = "not-a-uuid".data(using: .utf8)!
        #expect(throws: DataCoderError.badData) {
            _ = try coder.decode(invalid)
        }
    }

    @Test("URL decode fails with empty data")
    func urlDecodeEmpty() {
        let coder: AnyCoder<URL> = .data()
        #expect(throws: DataCoderError.badData) {
            _ = try coder.decode(Data())
        }
    }

    @Test("Bool decode treats any non-zero byte as true")
    func boolNonZeroIsTrue() throws {
        let coder: AnyCoder<Bool> = .data()
        let data = Data([0xFF])
        let decoded = try coder.decode(data)
        #expect(decoded == true)
    }

    @Test("empty string roundtrips")
    func emptyString() throws {
        let coder: AnyCoder<String> = .data()
        let encoded = try coder.encode("")
        #expect(encoded.isEmpty)
    }

    @Test("RawRepresentable roundtrip via LosslessDataConvertible")
    func rawRepresentable() throws {
        enum Status: Int, LosslessDataConvertible, Sendable {
            case active = 1
            case inactive = 2
        }

        let coder: AnyCoder<Status> = .data()
        let encoded = try coder.encode(.active)
        let decoded = try coder.decode(encoded)
        #expect(decoded == .active)
    }

    @Test("RawRepresentable decode fails with invalid raw value")
    func rawRepresentableInvalid() {
        enum Status: Int, LosslessDataConvertible, Sendable {
            case active = 1
            case inactive = 2
        }

        let coder: AnyCoder<Status> = .data()
        let intCoder: AnyCoder<Int> = .data()
        let invalidData = try! intCoder.encode(99)
        #expect(throws: DataCoderError.badData) {
            _ = try coder.decode(invalidData)
        }
    }

    @Test("error descriptions are non-empty")
    func errorDescriptions() {
        let errors: [DataCoderError] = [.noData, .badData]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
}
