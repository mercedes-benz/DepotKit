// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Orders keys by specificity (globstar < wildcard < segment), then by component count, then lexicographically.
extension Key: Comparable {
    public static func < (lhs: Key, rhs: Key) -> Bool {
        let count = min(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let lRank = lhs.components[i].specificityRank
            let rRank = rhs.components[i].specificityRank
            if lRank != rRank {
                return lRank < rRank
            }
        }

        if lhs.components.count != rhs.components.count {
            return lhs.components.count < rhs.components.count
        }

        for i in 0..<count {
            switch (lhs.components[i], rhs.components[i]) {
            case let (.segment(l), .segment(r)) where l != r:
                return l < r
            default:
                continue
            }
        }
        return false
    }
}

extension KeyComponent {
    /// Numeric rank for ordering: globstar (broadest) < wildcard < segment (most specific).
    @usableFromInline
    var specificityRank: Int {
        switch self {
        case .globstar: 0
        case .wildcard: 1
        case .segment: 2
        }
    }
}

extension DistinctKey: Comparable {
    public static func < (lhs: DistinctKey, rhs: DistinctKey) -> Bool {
        lhs.key < rhs.key
    }
}
