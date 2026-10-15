// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// Files whose header was damaged must not be mistaken for legacy files without a header.
@Suite("Damaged file headers")
struct DamagedFileHeaderTests {
    private static let value = Data((0..<64).map { UInt8($0) })

    private static func headered(_ value: Data, expiresAt: Date? = nil) -> Data {
        FileHeader(
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: expiresAt,
            crc32: CRC32.checksum(value),
        ).serialized() + value
    }

    private static func damaged(_ data: Data, at offsets: [Int]) -> Data {
        var data = data
        for offset in offsets {
            data[data.startIndex + offset] ^= 0x20
        }
        return data
    }

    private static func expectIntegrityFailure(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected an integrity-check failure")
        } catch DepotError.integrityCheckFailed {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - Parsing

    @Test("a header with one or two damaged magic bytes is reported as damaged", arguments: [[0], [3], [1, 2]])
    func nearMissMagic(offsets: [Int]) {
        let file = Self.damaged(Self.headered(Self.value), at: offsets)

        Self.expectIntegrityFailure { _ = try FileHeader.parse(file) }
        Self.expectIntegrityFailure { _ = try FileHeader.parse(file.prefix(FileHeader.size)) }
        Self.expectIntegrityFailure { _ = try FileHeader.parseAndValidate(file) }
    }

    @Test("a header with a destroyed magic is reported as damaged when its checksum matches the value")
    func destroyedMagicWithMatchingChecksum() {
        var file = Self.headered(Self.value)
        file.replaceSubrange(0..<8, with: Data(repeating: 0, count: 8))

        Self.expectIntegrityFailure { _ = try FileHeader.parseAndValidate(file) }
        Self.expectIntegrityFailure { _ = try FileHeader.parseAndValidate(file, at: Date()) }
    }

    @Test("a damaged header of an expired value is not read as a live legacy value")
    func damagedExpiredHeader() {
        let file = Self.damaged(
            Self.headered(Self.value, expiresAt: Date(timeIntervalSince1970: 1_700_000_100)),
            at: [0],
        )

        Self.expectIntegrityFailure { _ = try FileHeader.parseAndValidate(file, at: Date()) }
    }

    @Test(
        "files without a header are still read as legacy values",
        arguments: [
            Data(#"{"name":"legacy value","count":42,"enabled":true}"#.utf8),
            Data("bplist00".utf8) + Data((0..<40).map { UInt8(truncatingIfNeeded: $0 &* 37) }),
            Data((0..<100).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }),
            Data(repeating: 0, count: 64),
            Data("DPT".utf8),
        ]
    )
    func legacyFilesStayReadable(data: Data) throws {
        #expect(try FileHeader.parse(data) == nil)
        let (header, valueData) = try FileHeader.parseAndValidate(data)
        #expect(header == nil)
        #expect(valueData == data)
    }

    // MARK: - Depot Reads

    @Test("reading a value whose header magic was damaged fails instead of returning the raw file")
    func depotReadOfDamagedHeader() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        let key = depot.register(keyPath: "blob", coder: .data(Data.self))
        try depot.set(value: Self.value, for: key)

        let fileURL = try depot.fileURL(for: DistinctKey(key.components))
        try Self.damaged(try Data(contentsOf: fileURL), at: [1]).write(to: fileURL)

        Self.expectIntegrityFailure { _ = try depot.get(valueFor: key) }
        Self.expectIntegrityFailure { _ = try depot.metadata(for: key) }
    }

    @Test("an expired value whose header magic was damaged does not come back")
    func depotReadOfDamagedExpiredHeader() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = MockClock()
        let depot = Depot(
            configuration: .init(directoryURL: url, memoryCache: .disabled),
            overrides: .init(clock: clock, initSweepDelay: .seconds(3600)),
        )
        let key = depot.register(keyPath: "blob", coder: .data(Data.self), expiry: .seconds(60))
        try depot.set(value: Self.value, for: key)
        clock.advance(by: 120)
        #expect(try depot.get(valueFor: key) == nil)

        let fileURL = try depot.fileURL(for: DistinctKey(key.components))
        try Self.damaged(try Data(contentsOf: fileURL), at: [2]).write(to: fileURL)

        Self.expectIntegrityFailure { _ = try depot.get(valueFor: key) }
    }
}
