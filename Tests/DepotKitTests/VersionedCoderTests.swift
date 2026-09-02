// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct VersionedCoderTests {
    @Test("round-trips values at current version")
    func roundTrips() throws {
        let coder: AnyCoder<String> = .data().versioned(version: 1) { _, _ in nil }

        let values = ["", "hello", "😀🙋🏼‍♂️", String(repeating: "x", count: 5000)]
        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("migration receives nil version for unversioned data")
    func migratesUnversionedData() throws {
        let rawCoder: AnyCoder<String> = .data()
        let rawEncoded = try rawCoder.encode("old format")

        nonisolated(unsafe) var receivedVersion: Int?? = .some(999)
        let versionedCoder: AnyCoder<String> = .data().versioned(version: 1) { data, version in
            receivedVersion = version
            return String(data: data, encoding: .utf8)
        }

        let decoded = try versionedCoder.decode(rawEncoded)
        #expect(decoded == "old format")
        #expect(receivedVersion == .some(nil))
    }

    @Test("migration receives old version for versioned data")
    func migratesVersionedData() throws {
        let v1Coder: AnyCoder<String> = .data().versioned(version: 1) { _, _ in nil }
        let encoded = try v1Coder.encode("v1 data")

        nonisolated(unsafe) var receivedVersion: Int?
        let v2Coder: AnyCoder<String> = .json().versioned(version: 2) { data, version in
            receivedVersion = version
            return String(data: data, encoding: .utf8)
        }

        let decoded = try v2Coder.decode(encoded)
        #expect(decoded == "v1 data")
        #expect(receivedVersion == 1)
    }

    @Test("migration returning nil falls through to error")
    func migrationReturningNil() throws {
        let v1Coder: AnyCoder<String> = .data().versioned(version: 1) { _, _ in nil }
        let encoded = try v1Coder.encode("old")

        let v2Coder: AnyCoder<String> = .json().versioned(version: 2) { _, _ in nil }

        #expect(throws: VersionedCoderError.self) {
            _ = try v2Coder.decode(encoded)
        }
    }

    @Test("migration throwing wraps in migrationFailed")
    func migrationThrowing() throws {
        let rawData = Data("not versioned".utf8)

        let coder: AnyCoder<String> = .json().versioned(version: 1) { _, _ in
            throw TestError.migrationBroken
        }

        #expect(throws: VersionedCoderError.migrationFailed(underlyingError: TestError.migrationBroken)) {
            _ = try coder.decode(rawData)
        }
    }

    @Test("throws badData on completely empty input")
    func emptyInput() {
        let coder: AnyCoder<String> = .data().versioned(version: 1) { _, _ in nil }

        #expect(throws: VersionedCoderError.self) {
            _ = try coder.decode(Data())
        }
    }

    @Test("throws badData on truncated header")
    func truncatedHeader() {
        let coder: AnyCoder<String> = .data().versioned(version: 1) { _, _ in nil }

        #expect(throws: VersionedCoderError.self) {
            _ = try coder.decode(Data([0x00, 0x00, 0x00]))
        }
    }

    @Test("encoded data includes version header overhead")
    func headerOverhead() throws {
        let baseCoder: AnyCoder<String> = .data()
        let versionedCoder = baseCoder.versioned(version: 1) { _, _ in nil }

        let value = "hello"
        let baseSize = try baseCoder.encode(value).count
        let versionedSize = try versionedCoder.encode(value).count

        // 4 bytes header length (UInt32) + 8 bytes version (Int64) = 12 bytes overhead
        #expect(versionedSize == baseSize + 12)
    }

    @Test("current version data decodes without migration")
    func currentVersionNoMigration() throws {
        nonisolated(unsafe) var migrationCalled = false
        let coder: AnyCoder<String> = .data().versioned(version: 5) { _, _ in
            migrationCalled = true
            return nil
        }

        let encoded = try coder.encode("current")
        let decoded = try coder.decode(encoded)

        #expect(decoded == "current")
        #expect(!migrationCalled)
    }
}

private enum TestError: Error, Equatable {
    case migrationBroken
}
