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

/// Errors related to ``Coder/versioned(version:migration:)``.
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
        do {
            versionedData = try VersionedDataCoder().decode(data)
        } catch {
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

            throw error
        }

        if versionedData.header.version != version {
            LOG(
                level: .debug,
                message: "VersionedCoder: migrating from version \(versionedData.header.version) to \(version)"
            )
        }

        do {
            return try coder.decode(versionedData.data)
        } catch {
            do {
                if let migratedValue = try migration(versionedData.data, versionedData.header.version) {
                    return migratedValue
                }
            } catch {
                throw VersionedCoderError.migrationFailed(underlyingError: error)
            }

            throw VersionedCoderError.decodingFailed(underlyingError: error)
        }
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

/// Encodes/decodes ``VersionedData`` as `[header-length (UInt32 BE)] || [header] || [data]`.
private struct VersionedDataCoder: Coder {
    func encode(_ value: VersionedData) -> Data {
        let headerData = VersionHeaderCoder().encode(value.header)
        let headerDataLength = UInt32(headerData.count)

        // concat the values as binary data as follows
        // [header length (UInt32 BE)] || [header] || [data]
        return headerDataLength.bigEndianData + headerData + value.data
    }

    func decode(_ data: Data) throws(VersionedCoderError) -> VersionedData {
        let headerLength = MemoryLayout<UInt32>.size
        guard data.count > headerLength else {
            throw VersionedCoderError.badData
        }

        // reconstruct header and data from the binary data
        // [header length (UInt32 BE)] || [header] || [data]
        let headerDataLength = Int(UInt32(bigEndianData: data.prefix(headerLength)))
        // Header currently contains a single Int64 (version); may grow in future revisions.
        guard headerDataLength >= MemoryLayout<Int64>.size,
            data.count >= headerLength + headerDataLength
        else {
            throw VersionedCoderError.badData
        }

        let afterLength = data.dropFirst(headerLength)
        let headerData = afterLength.prefix(headerDataLength)
        let valueData = afterLength.dropFirst(headerDataLength)

        let header = VersionHeaderCoder().decode(Data(headerData))
        return VersionedData(header: header, data: Data(valueData))
    }
}
