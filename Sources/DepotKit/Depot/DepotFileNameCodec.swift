// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// The reversible mapping between canonical key identifiers and file-system
/// path components.
///
/// A file-backed depot selects one codec from the case sensitivity of its
/// volume when it is opened (see
/// ``select(volumeSupportsCaseSensitiveNames:depotURL:fallback:)``; if the
/// query fails, ``platformFallback`` is used) and uses it for every read,
/// write, removal and enumeration; file names carry no tag and are never
/// decoded by guessing the alphabet.
///
/// - ``base64URL``: RFC 4648 §5 Base64url *with* `=` padding (`+` → `-`,
///   `/` → `_`). Used on case-sensitive volumes. It is not injective on
///   case-insensitive volumes (`YWFh` and `YWFH` name the same file).
/// - ``base32``: RFC 4648 §6 Base32 (`A–Z`, `2–7`) *with* `=` padding. It only
///   uses one letter case and is therefore injective on case-sensitive and
///   case-insensitive volumes alike. Used on case-insensitive volumes.
///
/// Encoded names never start with `.`, so they can never be mistaken for the
/// depot's internal hidden files (``Depot/HiddenKeyPrefix``) and cannot form
/// `.`/`..` path segments.
///
/// - Note: Only to be used by ``Depot``!
enum DepotFileNameCodec: String, Sendable, CaseIterable {
    case base64URL
    case base32

    /// The maximum length, in UTF-8 bytes, of a single path component
    /// (APFS and HFS+ both limit names to 255 bytes).
    static let maximumPathComponentByteCount = 255

    /// The file extension appended to leaf components, including the dot (`.bin`).
    static let leafSuffixByteCount = Depot.PathExtension.utf8.count + 1

    // MARK: - Encoding

    /// Encodes a canonical identifier into a path component (without extension).
    func encode(_ identifier: String) -> String {
        switch self {
        case .base64URL:
            identifier.toBase64URL()
        case .base32:
            Self.base32Encode(Array(identifier.utf8))
        }
    }

    /// Decodes a path component (without extension) back into an identifier.
    ///
    /// Returns `nil` for anything this codec would not have produced: internal
    /// hidden names, foreign alphabets, non-canonical padding or trailing bits,
    /// invalid UTF-8 and empty identifiers. Decoding is therefore the exact
    /// inverse of ``encode(_:)``, so two different files can never decode to
    /// the same raw identifier.
    func decode(_ pathComponent: some StringProtocol) -> String? {
        guard !pathComponent.isEmpty, !pathComponent.hasPrefix(".") else {
            return nil
        }

        let bytes: [UInt8]?
        switch self {
        case .base64URL:
            bytes = Self.base64URLDecode(pathComponent)
        case .base32:
            bytes = Self.base32Decode(Array(pathComponent.utf8))
        }

        guard let bytes, !bytes.isEmpty else {
            return nil
        }

        // Strict UTF-8: decoding with repair must reproduce the exact bytes.
        let identifier = String(decoding: bytes, as: UTF8.self)
        guard identifier.utf8.elementsEqual(bytes) else {
            return nil
        }

        return identifier
    }

    /// The encoded length (without extension) of an identifier of `byteCount` UTF-8 bytes.
    func encodedLength(ofByteCount byteCount: Int) -> Int {
        switch self {
        case .base64URL:
            4 * ((byteCount + 2) / 3)
        case .base32:
            8 * ((byteCount + 4) / 5)
        }
    }

    /// The largest identifier, in UTF-8 bytes of its canonical (NFC) form,
    /// that fits into one path component.
    ///
    /// | Codec | Directory | Leaf (`.bin`) |
    /// |---|---|---|
    /// | ``base64URL`` | 189 | 186 |
    /// | ``base32`` | 155 | 155 |
    func maximumIdentifierByteCount(isLeaf: Bool) -> Int {
        let budget = Self.maximumPathComponentByteCount - (isLeaf ? Self.leafSuffixByteCount : 0)
        // Padded output is emitted in whole quanta: 3 bytes → 4 characters (Base64),
        // 5 bytes → 8 characters (Base32).
        return switch self {
        case .base64URL:
            3 * (budget / 4)
        case .base32:
            5 * (budget / 8)
        }
    }

    /// Throws ``DepotError/keyComponentTooLong(keyPath:byteCount:maximumByteCount:)``
    /// if a segment of `key` does not fit into a path component.
    ///
    /// The last component is measured as a leaf (including `.bin`) unless
    /// `lastComponentIsLeaf` is `false`; all earlier components are measured
    /// as directories.
    ///
    /// - Parameter lastComponentIsLeaf: Pass `false` for a prefix whose last
    ///   component also names a directory, such as the prefix of
    ///   `Depot.diskUsage(under:)`.
    func validate(_ key: Key, lastComponentIsLeaf: Bool = true) throws(DepotError) {
        let components = key.components
        for index in components.indices {
            guard case let .segment(identifier) = components[index] else {
                continue
            }

            let isLeaf = lastComponentIsLeaf && index == components.index(before: components.endIndex)
            let byteCount = identifier.utf8.count
            let maximum = maximumIdentifierByteCount(isLeaf: isLeaf)
            if byteCount > maximum {
                throw .keyComponentTooLong(keyPath: key.keyPath, byteCount: byteCount, maximumByteCount: maximum)
            }
        }
    }

    // MARK: - Base64url

    private static func base64URLDecode(_ pathComponent: some StringProtocol) -> [UInt8]? {
        var encoded = Array(pathComponent.utf8)
        for index in encoded.indices {
            switch encoded[index] {
            case UInt8(ascii: "-"): encoded[index] = UInt8(ascii: "+")
            case UInt8(ascii: "_"): encoded[index] = UInt8(ascii: "/")
            case UInt8(ascii: "+"), UInt8(ascii: "/"): return nil
            default: break
            }
        }

        guard let data = Data(base64Encoded: Data(encoded)) else {
            return nil
        }

        // Reject non-canonical spellings (e.g. non-zero trailing bits).
        let bytes = [UInt8](data)
        guard Data(bytes).base64EncodedData() == Data(encoded) else {
            return nil
        }
        return bytes
    }

    // MARK: - Base32 (RFC 4648 §6)

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    private static let base32DecodeTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (value, character) in base32Alphabet.enumerated() {
            table[Int(character)] = UInt8(value)
        }
        return table
    }()

    static func base32Encode(_ bytes: [UInt8]) -> String {
        var output = [UInt8]()
        output.reserveCapacity(8 * ((bytes.count + 4) / 5))

        var index = 0
        while index < bytes.count {
            let chunkCount = min(5, bytes.count - index)
            var buffer: UInt64 = 0
            for offset in 0..<5 {
                buffer <<= 8
                if offset < chunkCount {
                    buffer |= UInt64(bytes[index + offset])
                }
            }

            // 1, 2, 3, 4, 5 input bytes → 2, 4, 5, 7, 8 significant characters.
            let significant = (chunkCount * 8 + 4) / 5
            for position in 0..<8 {
                if position < significant {
                    let shift = UInt64(35 - position * 5)
                    output.append(base32Alphabet[Int((buffer >> shift) & 0x1F)])
                } else {
                    output.append(UInt8(ascii: "="))
                }
            }
            index += chunkCount
        }

        return String(decoding: output, as: UTF8.self)
    }

    static func base32Decode(_ encoded: [UInt8]) -> [UInt8]? {
        guard !encoded.isEmpty, encoded.count.isMultiple(of: 8) else {
            return nil
        }

        var output = [UInt8]()
        output.reserveCapacity(encoded.count / 8 * 5)

        var blockStart = 0
        while blockStart < encoded.count {
            let block = encoded[blockStart..<blockStart + 8]
            let isLastBlock = blockStart + 8 == encoded.count

            var significant = 8
            if let firstPadding = block.firstIndex(of: UInt8(ascii: "=")) {
                guard isLastBlock, block[firstPadding...].allSatisfy({ $0 == UInt8(ascii: "=") }) else {
                    return nil
                }
                significant = firstPadding - block.startIndex
            }

            // Valid significant-character counts and the bytes they carry.
            let byteCount: Int
            switch significant {
            case 8: byteCount = 5
            case 7: byteCount = 4
            case 5: byteCount = 3
            case 4: byteCount = 2
            case 2: byteCount = 1
            default: return nil
            }

            var buffer: UInt64 = 0
            for position in 0..<8 {
                buffer <<= 5
                if position < significant {
                    let value = base32DecodeTable[Int(block[block.startIndex + position])]
                    guard value != 0xFF else {
                        return nil
                    }
                    buffer |= UInt64(value)
                }
            }

            // Canonical form: unused trailing bits must be zero.
            let unusedBits = 40 - byteCount * 8
            if unusedBits > 0, buffer & ((1 << UInt64(unusedBits)) - 1) != 0 {
                return nil
            }

            for offset in 0..<byteCount {
                output.append(UInt8(truncatingIfNeeded: buffer >> UInt64(32 - offset * 8)))
            }
            blockStart += 8
        }

        return output
    }
}

// MARK: - Codec selection

extension DepotFileNameCodec {
    /// Returns whether the volume that holds (or will hold) `url` supports
    /// case-sensitive names, or `nil` if that cannot be determined.
    ///
    /// When `url` does not exist yet, the nearest existing ancestor is
    /// queried; no directories are created for probing.
    static func volumeSupportsCaseSensitiveNames(at url: URL, fileManager: FileManager = .default) -> Bool? {
        var candidate = url.standardizedFileURL
        while true {
            let path = candidate.path(percentEncoded: false)
            if fileManager.fileExists(atPath: path) {
                let values = try? candidate.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                return values?.volumeSupportsCaseSensitiveNames
            }

            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard !path.isEmpty, path != "/", parent.path(percentEncoded: false) != path else {
                return nil
            }
            candidate = parent
        }
    }

    /// The codec used when the volume's case sensitivity cannot be determined:
    /// ``base32`` on macOS, Mac Catalyst and the Simulator, which run on macOS
    /// volumes (case-insensitive by default), and ``base64URL`` on devices of
    /// all other platforms, whose volumes are case-sensitive.
    static var platformFallback: DepotFileNameCodec {
        #if os(macOS) || targetEnvironment(macCatalyst) || targetEnvironment(simulator)
        .base32
        #else
        .base64URL
        #endif
    }

    /// The name of the encoding used in log messages.
    var displayName: String {
        switch self {
        case .base64URL: "Base64url"
        case .base32: "Base32"
        }
    }

    /// Selects the codec for a depot from the case sensitivity of its volume.
    ///
    /// A case-sensitive volume selects ``base64URL``; a case-insensitive
    /// volume selects ``base32``. If the capability is unknown (`nil`),
    /// `fallback` is selected and an error naming it is logged.
    ///
    /// - Parameter fallback: The codec used when the capability is unknown;
    ///   defaults to ``platformFallback``.
    static func select(
        volumeSupportsCaseSensitiveNames: Bool?,
        depotURL: URL,
        fallback: DepotFileNameCodec = platformFallback,
    ) -> DepotFileNameCodec {
        switch volumeSupportsCaseSensitiveNames {
        case true?:
            return .base64URL
        case false?:
            return .base32
        case nil:
            LOG(
                level: .error,
                message:
                    """
                    Depot at \(depotURL.lastPathComponent) could not determine whether its volume supports \
                    case-sensitive names; using \(fallback.displayName) file names.
                    """,
            )
            return fallback
        }
    }
}
