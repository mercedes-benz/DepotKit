// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Key-to-URL mapping, base64url encoding, and file URL to key conversion helpers.
///
/// Note: Only to be used by ``Depot``!
extension DistinctKeyProtocol {
    func getFileURL(from depotURL: URL) -> URL {
        var fileURL = depotURL
        for component in components {
            fileURL = fileURL.appending(component: component.pathComponent, directoryHint: .notDirectory)
        }

        return fileURL.appendingPathExtension(Depot.PathExtension)  // .bin
    }
}

extension DistinctKey {
    static func from(fileURL: URL, relativeTo depotURL: URL) throws(String.Base64URLError) -> DistinctKey? {
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

        let filePathComponents =
            relativePath
            .split(separator: "/")
            .map(String.init)

        var components = [KeyComponent]()
        components.reserveCapacity(filePathComponents.count)
        for pathComponent in filePathComponents {
            try components.append(KeyComponent(pathComponent: pathComponent))
        }

        return DistinctKey(components)
    }
}

extension KeyComponent {
    var pathComponent: String {
        switch self {
        case let .segment(identifier):
            identifier.hasPrefix(Depot.HiddenKeyPrefix) ? identifier : identifier.toBase64URL()
        case .wildcard:
            preconditionFailure("Wildcard components cannot be converted to file path components")
        case .globstar:
            preconditionFailure("Globstar components cannot be converted to file path components")
        }
    }

    init(pathComponent: String) throws(String.Base64URLError) {
        if pathComponent.hasPrefix(Depot.HiddenKeyPrefix) {
            self = .segment(identifier: pathComponent)
        } else {
            let identifier = try pathComponent.fromBase64URL()
            self = .segment(identifier: identifier)
        }
    }

    /// Creates a key component by decoding a file path component (base64url).
    /// Returns `nil` if decoding fails (used during directory traversal
    /// where invalid entries are silently skipped).
    init?(decodingPathComponent pathComponent: String) {
        if pathComponent.hasPrefix(Depot.HiddenKeyPrefix) {
            self = .segment(identifier: pathComponent)
        } else if let identifier = try? pathComponent.fromBase64URL() {
            self = .segment(identifier: identifier)
        } else {
            return nil
        }
    }
}

// MARK: - Base64URL (RFC 4648 §5)

extension String {
    enum Base64URLError: Error {
        case decodingFailed
    }

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

    /// Decodes a base64url-encoded path component back to the original string (RFC 4648 §5).
    func fromBase64URL() throws(Base64URLError) -> String {
        var bytes = Data(utf8)
        for i in bytes.indices {
            switch bytes[i] {
            case 0x2D: bytes[i] = 0x2B  // - → +
            case 0x5F: bytes[i] = 0x2F  // _ → /
            default: break
            }
        }

        guard let decoded = Data(base64Encoded: bytes),
            let string = String(bytes: decoded, encoding: .utf8)
        else {
            throw Base64URLError.decodingFailed
        }

        return string
    }
}
