// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct FileHeaderTests {
    // MARK: - Serialization Round-Trip

    @Test("header serializes to exactly 28 bytes")
    func headerSize() {
        let header = FileHeader(modifiedAt: Date(), expiresAt: nil, crc32: 0)
        let data = header.serialized()
        #expect(data.count == 28)
    }

    @Test("serialized header round-trips through parse")
    func roundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expires = Date(timeIntervalSince1970: 1_700_003_600)
        let header = FileHeader(modifiedAt: now, expiresAt: expires, crc32: 0xDEAD_BEEF)

        let data = header.serialized()
        let parsed = try FileHeader.parse(data)

        #expect(parsed != nil)
        #expect(parsed!.modifiedAt == now)
        #expect(parsed!.expiresAt == expires)
        #expect(parsed!.crc32 == 0xDEAD_BEEF)
        #expect(parsed!.headerLength == 28)
        #expect(parsed!.formatVersion == 1)
        #expect(parsed!.minimumReaderVersion == 1)
    }

    @Test("nil expiresAt serializes as zero bits and parses back as nil")
    func noExpiry() throws {
        let header = FileHeader(modifiedAt: Date(), expiresAt: nil, crc32: 42)
        let data = header.serialized()
        let parsed = try FileHeader.parse(data)!

        #expect(parsed.expiresAt == nil)
    }

    // MARK: - Magic Detection

    @Test("parse returns nil for data without magic bytes (legacy file)")
    func legacyFileReturnsNil() throws {
        let legacyData = Data("hello world".utf8)
        let parsed = try FileHeader.parse(legacyData)
        #expect(parsed == nil)
    }

    @Test("parse returns nil for data shorter than 4 bytes")
    func tooShortReturnsNil() throws {
        let data = Data([0x44, 0x50, 0x54])  // "DPT" — incomplete magic
        let parsed = try FileHeader.parse(data)
        #expect(parsed == nil)
    }

    @Test("parse throws for data with magic but insufficient header bytes")
    func truncatedHeaderThrows() {
        let data = Data([0x44, 0x50, 0x54, 0x4D, 0x01])  // magic + 1 byte
        #expect(throws: DepotError.self) {
            _ = try FileHeader.parse(data)
        }
    }

    // MARK: - Version Checks

    @Test("parse throws incompatibleVersion when minimumReaderVersion > current")
    func incompatibleVersion() {
        var data = FileHeader(modifiedAt: Date(), expiresAt: nil, crc32: 0).serialized()
        data[5] = 99  // set minimumReaderVersion to 99

        #expect {
            _ = try FileHeader.parse(data)
        } throws: { error in
            guard let depotError = error as? DepotError,
                case let .incompatibleVersion(fileVersion: _, readerVersion: reader) = depotError
            else {
                return false
            }
            return reader == FileHeader.currentFormatVersion
        }
    }

    // MARK: - CRC32 Validation

    @Test("parseAndValidate succeeds when CRC32 matches")
    func crcValid() throws {
        let valueBytes = Data("payload".utf8)
        let crc = CRC32.checksum(valueBytes)
        let header = FileHeader(modifiedAt: Date(), expiresAt: nil, crc32: crc)
        let fileData = header.serialized() + valueBytes

        let (parsedHeader, parsedValue) = try FileHeader.parseAndValidate(fileData)
        #expect(parsedHeader != nil)
        #expect(parsedValue == valueBytes)
    }

    @Test("parseAndValidate throws when CRC32 does not match")
    func crcInvalid() {
        let valueBytes = Data("payload".utf8)
        let header = FileHeader(modifiedAt: Date(), expiresAt: nil, crc32: 0xBAD0_BAD0)
        let fileData = header.serialized() + valueBytes

        #expect {
            _ = try FileHeader.parseAndValidate(fileData)
        } throws: { error in
            guard let depotError = error as? DepotError,
                case .integrityCheckFailed = depotError
            else {
                return false
            }
            return true
        }
    }

    @Test("parseAndValidate returns nil header for legacy data (full data as value)")
    func legacyPassthrough() throws {
        let legacyData = Data("legacy value".utf8)
        let (header, value) = try FileHeader.parseAndValidate(legacyData)
        #expect(header == nil)
        #expect(value == legacyData)
    }

    // MARK: - Expiry

    @Test("isExpired returns false when expiresAt is nil")
    func noExpiryNeverExpires() {
        let header = FileHeader(modifiedAt: Date(), expiresAt: nil, crc32: 0)
        #expect(!header.isExpired(at: Date.distantFuture))
    }

    @Test("isExpired returns false before expiresAt")
    func notYetExpired() {
        let future = Date().addingTimeInterval(3600)
        let header = FileHeader(modifiedAt: Date(), expiresAt: future, crc32: 0)
        #expect(!header.isExpired(at: Date()))
    }

    @Test("isExpired returns true at exactly expiresAt")
    func expiredAtBoundary() {
        let now = Date()
        let header = FileHeader(modifiedAt: now, expiresAt: now, crc32: 0)
        #expect(header.isExpired(at: now))
    }

    @Test("isExpired returns true after expiresAt")
    func expiredAfter() {
        let past = Date().addingTimeInterval(-100)
        let header = FileHeader(modifiedAt: Date().addingTimeInterval(-200), expiresAt: past, crc32: 0)
        #expect(header.isExpired(at: Date()))
    }

    // MARK: - CRC32 Algorithm

    @Test("CRC32 produces known checksum for empty data")
    func crc32Empty() {
        let crc = CRC32.checksum(Data())
        #expect(crc == 0x0000_0000)
    }

    @Test("CRC32 produces known checksum for known input")
    func crc32KnownInput() {
        // "123456789" → CRC32 = 0xCBF43926
        let data = Data("123456789".utf8)
        let crc = CRC32.checksum(data)
        #expect(crc == 0xCBF4_3926)
    }

    @Test("CRC32 is deterministic")
    func crc32Deterministic() {
        let data = Data(repeating: 0xAB, count: 256)
        let crc1 = CRC32.checksum(data)
        let crc2 = CRC32.checksum(data)
        #expect(crc1 == crc2)
    }
}
