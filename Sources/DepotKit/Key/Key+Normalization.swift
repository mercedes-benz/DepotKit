// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

// MARK: - Canonical identifiers (Unicode NFC)

extension KeyComponent {
    /// This component with its identifier in Unicode Normalization Form C,
    /// or `nil` if it already is canonical.
    ///
    /// Swift `String` equality already treats canonically equivalent spellings
    /// (e.g. `"é"` and `"e\u{301}"`) as equal, but their UTF-8 bytes — and
    /// therefore their file names — differ. Keys store NFC identifiers so
    /// that equal keys always map to the same file. Letter case is preserved.
    var canonicalizedIfNeeded: KeyComponent? {
        guard case let .segment(identifier) = self, !identifier.utf8.allSatisfy({ $0 < 0x80 }) else {
            // Wildcards, globstars and ASCII identifiers are already canonical.
            return nil
        }

        let normalized = identifier.precomposedStringWithCanonicalMapping
        return normalized.utf8.elementsEqual(identifier.utf8) ? nil : .segment(identifier: normalized)
    }
}

extension Array where Element == KeyComponent {
    /// The components with every identifier in Unicode Normalization Form C.
    func canonicalized() -> [KeyComponent] {
        var result: [KeyComponent]?
        for index in indices {
            if let canonical = self[index].canonicalizedIfNeeded {
                if result == nil {
                    result = self
                }
                result?[index] = canonical
            }
        }
        return result ?? self
    }
}

/// Implemented by DepotKit's concrete key types, whose components are
/// canonical by construction. Converting between them reuses the stored
/// ``Key`` instead of re-validating and re-normalizing its components.
protocol CanonicalKeyConvertible {
    var canonicalKey: Key { get }
}

extension Key: CanonicalKeyConvertible {
    var canonicalKey: Key { self }
}

extension DistinctKey: CanonicalKeyConvertible {
    var canonicalKey: Key { key }
}

extension TypedKey: CanonicalKeyConvertible {
    var canonicalKey: Key { key }
}

extension TypedDistinctKey: CanonicalKeyConvertible {
    var canonicalKey: Key { key }
}
