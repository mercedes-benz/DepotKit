// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Key-to-URL mapping, file-name encoding, and file URL to key conversion helpers.
///
/// User key components are *always* encoded with the depot's
/// ``DepotFileNameCodec``; no identifier spelling bypasses the encoding.
/// Internal files (metadata, lock) are addressed by fixed
/// hidden names via ``Depot/internalFileURL(named:in:)`` and are never
/// produced or decoded by the key mapping, because encoded names never start
/// with `.`.
///
/// Note: Only to be used by ``Depot``!
extension DistinctKey {
    /// The file URL that stores the value of this key.
    ///
    /// - Throws: ``DepotError/keyComponentTooLong(keyPath:byteCount:maximumByteCount:)``
    ///   if a component does not fit into a file name.
    func getFileURL(from depotURL: URL, codec: DepotFileNameCodec) throws(DepotError) -> URL {
        try codec.validate(key)

        var fileURL = depotURL
        for component in components {
            fileURL = fileURL.appending(component: component.pathComponent(using: codec), directoryHint: .notDirectory)
        }

        return fileURL.appendingPathExtension(Depot.PathExtension)  // .bin
    }

    /// Reconstructs the key stored at `fileURL`, or returns `nil` if the URL
    /// is not a user value file of this depot (wrong extension, outside the
    /// depot, internal hidden file, or a name the codec would not produce).
    static func from(fileURL: URL, relativeTo depotURL: URL, codec: DepotFileNameCodec) -> DistinctKey? {
        let filePath = fileURL.path(percentEncoded: false)
        let depotPath = depotURL.path(percentEncoded: false)

        guard filePath.hasSuffix("." + Depot.PathExtension) else {
            return nil
        }

        // We need to build the key from the absolute path of fileURL.
        // Therefore we first need to construct a relative path based on depotURL.
        //
        // CAUTION: On actual devices the paths may be slightly different, e.g.:
        // fileURL: "/private/var/mobile/Containers/Data/.../.bin"
        // depotURL: "/var/mobile/Containers/Data/..."
        guard let depotRange = filePath.range(of: depotPath) else {
            return nil
        }

        // Strip depot prefix and .bin extension via string slicing
        let extensionLength = Depot.PathExtension.count + 1  // ".bin"
        let relativePath = filePath[depotRange.upperBound...]
            .dropLast(extensionLength)

        let filePathComponents = relativePath.split(separator: "/")
        guard !filePathComponents.isEmpty else {
            return nil
        }

        var components = [KeyComponent]()
        components.reserveCapacity(filePathComponents.count)
        for pathComponent in filePathComponents {
            guard let component = KeyComponent(decodingPathComponent: pathComponent, using: codec) else {
                return nil
            }
            components.append(component)
        }

        return DistinctKey(components)
    }
}

extension KeyComponent {
    /// The encoded path component of a segment (without extension).
    func pathComponent(using codec: DepotFileNameCodec) -> String {
        switch self {
        case let .segment(identifier):
            codec.encode(identifier)
        case .wildcard:
            preconditionFailure("Wildcard components cannot be converted to file path components")
        case .globstar:
            preconditionFailure("Globstar components cannot be converted to file path components")
        }
    }

    /// Creates a key component by decoding a file path component.
    /// Returns `nil` if decoding fails (used during directory traversal
    /// where invalid entries and internal hidden files are skipped).
    init?(decodingPathComponent pathComponent: some StringProtocol, using codec: DepotFileNameCodec) {
        guard let identifier = codec.decode(pathComponent) else {
            return nil
        }
        self = .segment(identifier: identifier)
    }
}

extension Depot {
    /// The URL of an internal (hidden) depot file such as the metadata.
    ///
    /// Internal files are identified by this fixed location, never by a key,
    /// so no user key can address them.
    static func internalFileURL(named name: String, in depotURL: URL) -> URL {
        depotURL.appending(component: "\(HiddenKeyPrefix)\(name)", directoryHint: .notDirectory)
    }
}

// MARK: - Base64URL (RFC 4648 §5)

extension String {
    /// Encodes this string as a base64url path component (RFC 4648 §5).
    /// Uses `-` and `_` instead of `+` and `/`, making the output safe for filesystem paths.
    func toBase64URL() -> String {
        var bytes = Data(utf8).base64EncodedData()
        for i in bytes.indices {
            switch bytes[i] {
            case 0x2B: bytes[i] = 0x2D  // + → -
            case 0x2F: bytes[i] = 0x5F  // / → _
            default: break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
