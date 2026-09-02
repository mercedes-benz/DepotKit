// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import zlib

// MARK: - FileHeader

/// Internal depot file header (28 bytes).
///
/// Layout:
/// ```
/// Offset  Size  Field
/// ─────────────────────────────────
///  0      4     magic ("DPTM")
///  4      1     format version (0x01)
///  5      1     minimum reader version (0x01)
///  6      2     headerLength (UInt16 BE)
///  8      8     modifiedAt (Float64 BE, unix timestamp)
/// 16      8     expiresAt (Float64 BE, 0x0 = never)
/// 24      4     CRC32 of value bytes
/// ─────────────────────────────────
/// ```
///
/// ## Version Upgrade Strategy
///
/// Files are upgraded lazily: existing v1 files are readable by any future
/// reader (as long as `minimumReaderVersion <= currentFormatVersion`) and are
/// rewritten with the current format version on the next successful write.
/// No eager migration pass is required.
struct FileHeader: Sendable, Equatable {
    static let magic: UInt32 = 0x4450_544D  // "DPTM"
    static let currentFormatVersion: UInt8 = 1
    static let currentMinimumReaderVersion: UInt8 = 1
    static let size: Int = 28

    let formatVersion: UInt8
    let minimumReaderVersion: UInt8
    let headerLength: UInt16
    let modifiedAt: Date
    let expiresAt: Date?
    let crc32: UInt32

    // expiresAt bit pattern 0x0 is the "never expires" sentinel — Date(timeIntervalSince1970: 0) is reserved.
    init(modifiedAt: Date, expiresAt: Date?, crc32: UInt32) {
        assert(
            expiresAt == nil || expiresAt!.timeIntervalSince1970 != 0,
            "expiresAt must not be exactly the Unix epoch (reserved as 'no expiry' sentinel)"
        )
        self.formatVersion = Self.currentFormatVersion
        self.minimumReaderVersion = Self.currentMinimumReaderVersion
        self.headerLength = UInt16(Self.size)
        self.modifiedAt = modifiedAt
        self.expiresAt = expiresAt
        self.crc32 = crc32
    }

    private init(
        formatVersion: UInt8,
        minimumReaderVersion: UInt8,
        headerLength: UInt16,
        modifiedAt: Date,
        expiresAt: Date?,
        crc32: UInt32
    ) {
        self.formatVersion = formatVersion
        self.minimumReaderVersion = minimumReaderVersion
        self.headerLength = headerLength
        self.modifiedAt = modifiedAt
        self.expiresAt = expiresAt
        self.crc32 = crc32
    }

    // MARK: - Serialization

    func serialized() -> Data {
        var data = Data(capacity: Self.size)
        data.appendBigEndian(Self.magic)
        data.append(formatVersion)
        data.append(minimumReaderVersion)
        data.appendBigEndian(headerLength)
        data.appendBigEndian(modifiedAt.timeIntervalSince1970.bitPattern)
        let expiresAtBits = expiresAt?.timeIntervalSince1970.bitPattern ?? 0
        data.appendBigEndian(expiresAtBits)
        data.appendBigEndian(crc32)
        return data
    }

    // MARK: - Parsing

    /// Attempts to parse a file header from the given data.
    ///
    /// Returns `nil` if the data does not start with the magic bytes (legacy file).
    /// Throws if the header is present but malformed or requires a newer reader.
    static func parse(_ data: Data) throws -> FileHeader? {
        guard data.count >= 4 else {
            return nil
        }

        let magic = data.readBigEndianUInt32(at: 0)
        guard magic == Self.magic else {
            return nil
        }

        guard data.count >= Self.size else {
            throw DepotError.integrityCheckFailed(reason: "Header too short")
        }

        let formatVersion = data[4]
        let minimumReaderVersion = data[5]

        guard minimumReaderVersion <= Self.currentFormatVersion else {
            throw DepotError.incompatibleVersion(
                fileVersion: formatVersion,
                readerVersion: Self.currentFormatVersion
            )
        }

        let headerLength = data.readBigEndianUInt16(at: 6)
        let modifiedBits = data.readBigEndianUInt64(at: 8)
        let expiresBits = data.readBigEndianUInt64(at: 16)
        let crc32 = data.readBigEndianUInt32(at: 24)

        let modifiedAt = Date(timeIntervalSince1970: Double(bitPattern: modifiedBits))
        let expiresAt: Date? = expiresBits == 0 ? nil : Date(timeIntervalSince1970: Double(bitPattern: expiresBits))

        return FileHeader(
            formatVersion: formatVersion,
            minimumReaderVersion: minimumReaderVersion,
            headerLength: headerLength,
            modifiedAt: modifiedAt,
            expiresAt: expiresAt,
            crc32: crc32
        )
    }

    /// Parses the header and validates the CRC32 of the value bytes.
    ///
    /// Returns the parsed header and validated value data, or `nil` + full data for legacy files.
    static func parseAndValidate(_ fileData: Data) throws -> (header: FileHeader?, valueData: Data) {
        guard let header = try parse(fileData) else {
            return (nil, fileData)
        }

        let valueBytes = try validateCRC(fileData: fileData, header: header)
        return (header, valueBytes)
    }

    /// Parses the header and validates the CRC32 of the value bytes, skipping
    /// validation entirely when the value has already expired.
    ///
    /// Returns `nil` for both header and data when the value is expired (caller
    /// should treat as absent). Returns `nil` header + full data for legacy files.
    static func parseAndValidate(_ fileData: Data, at now: Date) throws -> (header: FileHeader?, valueData: Data)? {
        guard let header = try parse(fileData) else {
            return (nil, fileData)
        }

        if header.isExpired(at: now) {
            return nil
        }

        let valueBytes = try validateCRC(fileData: fileData, header: header)
        return (header, valueBytes)
    }

    private static func validateCRC(fileData: Data, header: FileHeader) throws -> Data {
        let offset = Int(header.headerLength)
        guard fileData.count >= offset else {
            throw DepotError.integrityCheckFailed(reason: "File shorter than header length")
        }

        let valueBytes = fileData.suffix(from: fileData.startIndex + offset)
        let computedCRC = CRC32.checksum(valueBytes)

        guard computedCRC == header.crc32 else {
            throw DepotError.integrityCheckFailed(
                reason: "CRC32 mismatch (expected \(header.crc32), got \(computedCRC))"
            )
        }

        return valueBytes
    }

    /// Returns true if the value has expired according to the given date.
    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else {
            return false
        }
        return now >= expiresAt
    }

    /// Reads only the header from a file and returns whether the value is non-expired.
    ///
    /// Returns `true` if the file contains a non-expired value (or is a legacy file without a header).
    /// Returns `false` if the header indicates the value has expired.
    /// Returns `nil` if the file cannot be read.
    static func isNonExpired(at fileURL: URL, now: Date) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        guard let headerData = try? handle.read(upToCount: FileHeader.size) else {
            return nil
        }
        // try? is intentional: incompatible/malformed headers are treated as "exists"
        // (conservative — the file is physically present even if unreadable by this version)
        if let header = try? FileHeader.parse(headerData) {
            return !header.isExpired(at: now)
        }
        return true
    }
}

// MARK: - CRC32

enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return 0
            }
            precondition(rawBuffer.count <= UInt32.max, "CRC32 does not support data larger than 4 GB")
            let result = zlib.crc32(0, baseAddress.assumingMemoryBound(to: UInt8.self), uInt(rawBuffer.count))
            return UInt32(result)
        }
    }
}

// MARK: - Data Helpers

extension Data {
    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        withUnsafePointer(to: &bigEndian) { ptr in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    fileprivate mutating func appendBigEndian(_ value: UInt16) {
        var bigEndian = value.bigEndian
        withUnsafePointer(to: &bigEndian) { ptr in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    fileprivate mutating func appendBigEndian(_ value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafePointer(to: &bigEndian) { ptr in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    fileprivate func readBigEndianUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { buffer in
            UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    fileprivate func readBigEndianUInt16(at offset: Int) -> UInt16 {
        withUnsafeBytes { buffer in
            UInt16(bigEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    fileprivate func readBigEndianUInt64(at offset: Int) -> UInt64 {
        withUnsafeBytes { buffer in
            UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }
}
