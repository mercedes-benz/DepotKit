// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

extension AnyCoder {
    /// Wraps this coder with versioning for data migration support.
    ///
    /// ```swift
    /// depot.register(key: ..., coder: .json().versioned(version: 2) { data, version in
    ///     // migrate from older version
    /// })
    /// ```
    public func versioned(
        version: Int,
        migration: @escaping @Sendable (_ data: Data, _ version: Int?) throws -> Value?,
    ) -> AnyCoder<Value> {
        VersionedCoder(self, version: version, migration: migration).eraseToAnyCoder()
    }
}

/// Errors related to ``AnyCoder/versioned(version:migration:)``.
public enum VersionedCoderError: Error {
    /// The data is corrupted and can't be recovered.
    case badData

    /// The migration closure threw an error.
    case migrationFailed(underlyingError: Error)

    /// Encoding with the wrapped coder failed.
    case encodingFailed(underlyingError: Error)

    /// Decoding with the wrapped coder failed.
    case decodingFailed(underlyingError: Error)
}

extension VersionedCoderError: Equatable {
    public static func == (lhs: VersionedCoderError, rhs: VersionedCoderError) -> Bool {
        switch (lhs, rhs) {
        case (.badData, .badData),
            (.migrationFailed, .migrationFailed),
            (.encodingFailed, .encodingFailed),
            (.decodingFailed, .decodingFailed):
            true
        default:
            false
        }
    }
}

extension VersionedCoderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badData:
            "The versioned data is corrupted and cannot be recovered."
        case let .migrationFailed(error):
            "Data migration failed: \(error.localizedDescription)"
        case let .encodingFailed(error):
            "Versioned encoding failed: \(error.localizedDescription)"
        case let .decodingFailed(error):
            "Versioned decoding failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - VersionedCoder

/// A coder that prepends a version header to encoded data and delegates to a migration closure on version mismatch.
struct VersionedCoder<Value: Sendable>: Coder {
    let coder: AnyCoder<Value>
    let version: Int
    private let migration: @Sendable (Data, Int?) throws -> Value?

    init<C>(_ coder: C, version: Int, migration: @escaping @Sendable (Data, Int?) throws -> Value?)
    where C: Coder, C.Value == Value {
        self.coder = coder.eraseToAnyCoder()
        self.version = version
        self.migration = migration
    }

    var coderDescription: String { "\(coder.coderDescription).versioned(v\(version))" }

    func encode(_ value: Value) throws(VersionedCoderError) -> Data {
        let data: Data
        do {
            data = try coder.encode(value)
        } catch {
            throw VersionedCoderError.encodingFailed(underlyingError: error)
        }

        let header = VersionHeader(version: version)
        let versionedData = VersionedData(header: header, data: data)

        return VersionedDataCoder().encode(versionedData)
    }

    func decode(_ data: Data) throws(VersionedCoderError) -> Value {
        let versionedData: VersionedData

        guard VersionedDataCoder.hasVersionedMagic(data) else {
            LOG(
                level: .debug,
                message: "VersionedCoder: no version header found, attempting migration from unversioned data"
            )
            do {
                if let migratedValue = try migration(data, nil) {
                    return migratedValue
                }
            } catch {
                throw VersionedCoderError.migrationFailed(underlyingError: error)
            }

            throw VersionedCoderError.badData
        }

        versionedData = try VersionedDataCoder().decode(data)

        if versionedData.header.version == version {
            do {
                return try coder.decode(versionedData.data)
            } catch {
                throw VersionedCoderError.decodingFailed(underlyingError: error)
            }
        }

        LOG(
            level: .debug,
            message: "VersionedCoder: migrating from version \(versionedData.header.version) to \(version)"
        )

        do {
            if let migratedValue = try migration(versionedData.data, versionedData.header.version) {
                return migratedValue
            }
        } catch {
            throw VersionedCoderError.migrationFailed(underlyingError: error)
        }

        throw VersionedCoderError.decodingFailed(
            underlyingError: VersionedCoderError.badData
        )
    }

}

/// Version tag prepended to versioned data — currently a single `Int64`.
private struct VersionHeader: Sendable {
    let version: Int
}

/// Container pairing a ``VersionHeader`` with the raw encoded payload.
private struct VersionedData: Sendable {
    let header: VersionHeader
    let data: Data
}

/// Encodes/decodes a ``VersionHeader`` as a big-endian `Int64`.
private struct VersionHeaderCoder: Coder {
    func encode(_ value: VersionHeader) -> Data {
        // version as Int64 (BE)
        let version = Int64(value.version)

        return version.bigEndianData
    }

    func decode(_ data: Data) -> VersionHeader {
        // version as Int64 (BE)
        let version = Int(Int64(bigEndianData: data))

        return VersionHeader(version: version)
    }
}

/// Encodes/decodes ``VersionedData`` as `[magic (8B)] || [header-length (UInt32 BE)] || [header] || [data]`.
///
/// The 8-byte magic `DKVERS01` (`44 4B 56 45 52 53 30 31`) is chosen to be long
/// enough that accidental collisions with arbitrary binary payloads (e.g. FourCC
/// atoms, protocol headers) are effectively impossible. The trailing `01` is the
/// envelope format version, reserved for future structural changes.
private struct VersionedDataCoder: Coder {
    /// `DKVERS01` in ASCII — 8 bytes to avoid collisions with arbitrary binary payloads.
    static let magic = Data([0x44, 0x4B, 0x56, 0x45, 0x52, 0x53, 0x30, 0x31])

    func encode(_ value: VersionedData) -> Data {
        let headerData = VersionHeaderCoder().encode(value.header)
        let headerDataLength = UInt32(headerData.count)

        // [magic] || [header length (UInt32 BE)] || [header] || [data]
        return Self.magic + headerDataLength.bigEndianData + headerData + value.data
    }

    func decode(_ data: Data) throws(VersionedCoderError) -> VersionedData {
        let magicSize = Self.magic.count
        let headerLengthSize = MemoryLayout<UInt32>.size

        guard data.count >= magicSize + headerLengthSize,
            data.prefix(magicSize) == Self.magic
        else {
            throw VersionedCoderError.badData
        }

        // [magic] || [header length (UInt32 BE)] || [header] || [data]
        let afterMagic = data.dropFirst(magicSize)
        let headerDataLength = Int(UInt32(bigEndianData: afterMagic.prefix(headerLengthSize)))

        guard headerDataLength >= MemoryLayout<Int64>.size,
            data.count >= magicSize + headerLengthSize + headerDataLength
        else {
            throw VersionedCoderError.badData
        }

        let afterLengthField = afterMagic.dropFirst(headerLengthSize)
        let headerData = afterLengthField.prefix(headerDataLength)
        let valueData = afterLengthField.dropFirst(headerDataLength)

        let header = VersionHeaderCoder().decode(Data(headerData))
        return VersionedData(header: header, data: valueData)
    }

    /// Checks whether `data` starts with the versioned magic bytes.
    static func hasVersionedMagic(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }
}
