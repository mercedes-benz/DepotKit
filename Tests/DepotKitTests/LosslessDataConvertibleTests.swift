// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

private enum ThreeCaseEnum: Int, CaseIterable, Equatable, LosslessDataConvertible {
    case one
    case two
    case three
}

private enum StringEnum: String, CaseIterable, Equatable, LosslessDataConvertible {
    case alpha
    case beta
}

@Suite
struct LosslessDataConvertibleTests {
    // MARK: - Data

    @Suite
    struct DataTests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next in [
                Data(),
                EncryptionConfiguration.generateKey(),
                "hello world".data(using: .utf8)!,
            ] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(Data(dataRepresentation: dataRepresentation) == next)
            }
        }
    }

    // MARK: - Bool

    @Suite
    struct BoolTests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next in [true, false] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(Bool(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("decodes non-zero as true")
        func nonZeroIsTrue() throws {
            let data = UInt8(42).bigEndianData
            #expect(Bool(dataRepresentation: data) == true)
        }

        @Test("returns nil for empty data")
        func emptyData() {
            #expect(Bool(dataRepresentation: Data()) == nil)
        }
    }

    // MARK: - Int

    @Suite
    struct IntTests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next in [0, 1, -1, 10_120_120_201_021_202, -42, Int.min, Int.max] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(Int(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for truncated data")
        func truncatedData() {
            let truncated = Data([0x01, 0x02])
            #expect(Int(dataRepresentation: truncated) == nil)
        }
    }

    // MARK: - UInt

    @Suite
    struct UIntTests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next: UInt in [0, 1, 42, UInt.max] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(UInt(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for truncated data")
        func truncatedData() {
            let truncated = Data([0xFF])
            #expect(UInt(dataRepresentation: truncated) == nil)
        }
    }

    // MARK: - Int8

    @Suite
    struct Int8Tests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next: Int8 in [0, 1, -1, .min, .max] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(Int8(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for empty data")
        func emptyData() {
            #expect(Int8(dataRepresentation: Data()) == nil)
        }
    }

    // MARK: - Int16

    @Suite
    struct Int16Tests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next: Int16 in [0, 1, -1, .min, .max, 256, -256] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(Int16(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for single byte")
        func truncatedData() {
            #expect(Int16(dataRepresentation: Data([0x01])) == nil)
        }
    }

    // MARK: - Int32

    @Suite
    struct Int32Tests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next: Int32 in [0, 1, -1, .min, .max] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(Int32(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for truncated data")
        func truncatedData() {
            #expect(Int32(dataRepresentation: Data([0x01, 0x02])) == nil)
        }
    }

    // MARK: - Int64

    @Suite
    struct Int64Tests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next: Int64 in [0, 1, -1, .min, .max] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(Int64(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for truncated data")
        func truncatedData() {
            #expect(Int64(dataRepresentation: Data([0x01, 0x02, 0x03, 0x04])) == nil)
        }
    }

    // MARK: - UInt8

    @Suite
    struct UInt8Tests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next: UInt8 in [0, 1, 127, 255] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(UInt8(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for empty data")
        func emptyData() {
            #expect(UInt8(dataRepresentation: Data()) == nil)
        }
    }

    // MARK: - UInt16

    @Suite
    struct UInt16Tests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next: UInt16 in [0, 1, 256, .max] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(UInt16(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for single byte")
        func truncatedData() {
            #expect(UInt16(dataRepresentation: Data([0x01])) == nil)
        }
    }

    // MARK: - UInt32

    @Suite
    struct UInt32Tests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next: UInt32 in [0, 1, .max] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(UInt32(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for truncated data")
        func truncatedData() {
            #expect(UInt32(dataRepresentation: Data([0x01, 0x02])) == nil)
        }
    }

    // MARK: - UInt64

    @Suite
    struct UInt64Tests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next: UInt64 in [0, 1, .max] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(UInt64(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for truncated data")
        func truncatedData() {
            #expect(UInt64(dataRepresentation: Data([0x01, 0x02, 0x03, 0x04])) == nil)
        }
    }

    // MARK: - Float

    @Suite
    struct FloatTests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next: Float in [0.0, 1.0, -1.0, 120_120.79, -42.2, .greatestFiniteMagnitude, .leastNonzeroMagnitude] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(Float(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for truncated data")
        func truncatedData() {
            #expect(Float(dataRepresentation: Data([0x01, 0x02])) == nil)
        }
    }

    // MARK: - Double

    @Suite
    struct DoubleTests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next in [
                0.0, 1.0, -1.0, 120_120.79, -42.2, Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude,
            ] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(Double(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for truncated data")
        func truncatedData() {
            #expect(Double(dataRepresentation: Data([0x01, 0x02, 0x03, 0x04])) == nil)
        }
    }

    // MARK: - String

    @Suite
    struct StringTests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next in ["", "hello world", "🤣", "Ü Ö Ä ß", "日本語"] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(String(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for invalid UTF-8")
        func invalidUTF8() {
            let invalid = Data([0xFE, 0xFF])
            #expect(String(dataRepresentation: invalid) == nil)
        }
    }

    // MARK: - URL

    @Suite
    struct URLTests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next in [
                URL(string: "https://mercedes-benz.com")!,
                URL(fileURLWithPath: "/users/depotkit/Desktop"),
                URL(string: "https://example.com/path?q=1&b=2#frag")!,
            ] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(URL(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for empty string")
        func emptyString() {
            let data = "".data(using: .utf8)!
            #expect(URL(dataRepresentation: data) == nil)
        }
    }

    // MARK: - UUID

    @Suite
    struct UUIDTests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next in [
                UUID(uuidString: "550e8400-e29b-11d4-a716-446655440000")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            ] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(UUID(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for invalid UUID string")
        func invalidString() {
            let data = "not-a-uuid".data(using: .utf8)!
            #expect(UUID(dataRepresentation: data) == nil)
        }
    }

    // MARK: - Date

    @Suite
    struct DateTests {
        @Test("roundtrips")
        func roundtrip() throws {
            for next in [
                Date.distantPast,
                Date.distantFuture,
                Date(timeIntervalSinceReferenceDate: 0),
                Date(timeIntervalSinceReferenceDate: 12_012_012),
                Date(timeIntervalSinceReferenceDate: -12_012_012),
            ] {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(Date(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for truncated data")
        func truncatedData() {
            #expect(Date(dataRepresentation: Data([0x01, 0x02])) == nil)
        }
    }

    // MARK: - RawRepresentable

    @Suite
    struct RawRepresentableTests {
        @Test("roundtrips Int-backed enum")
        func intEnum() throws {
            for next in ThreeCaseEnum.allCases {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(ThreeCaseEnum(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("roundtrips String-backed enum")
        func stringEnum() throws {
            for next in StringEnum.allCases {
                let dataRepresentation = try #require(next.dataRepresentation)
                #expect(StringEnum(dataRepresentation: dataRepresentation) == next)
            }
        }

        @Test("returns nil for invalid raw value")
        func invalidRawValue() throws {
            let invalidInt: Int = 99
            let data = try #require(invalidInt.dataRepresentation)
            #expect(ThreeCaseEnum(dataRepresentation: data) == nil)
        }
    }

    // MARK: - Extra bytes behavior

    @Suite
    struct ExtraBytesTests {
        @Test("decodes correctly when data has trailing bytes")
        func trailingBytesIgnored() throws {
            let original: Int32 = 42
            var data = try #require(original.dataRepresentation)
            data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
            #expect(Int32(dataRepresentation: data) == original)
        }
    }
}
