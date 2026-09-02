// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

extension KeyComponent {
    /// Returns `true` if this component is a wildcard.
    @inlinable
    @inline(__always)
    public var isWildcard: Bool {
        if case .wildcard = self {
            return true
        }
        return false
    }

    /// Returns `true` if this component is a globstar.
    @inlinable
    @inline(__always)
    public var isGlobstar: Bool {
        if case .globstar = self {
            return true
        }
        return false
    }

    /// Returns `true` if this component is a wildcard or globstar (i.e., not a segment).
    @inlinable
    @inline(__always)
    public var isPattern: Bool {
        if case .segment = self {
            return false
        }
        return true
    }
}

extension String {
    private static let Wildcard = "*"
    private static let Globstar = "**"
    private static let Separator = "/"

    /// Renders the key's components as a slash-separated path, escaping special characters.
    init(key: some KeyProtocol) {
        var result = ""
        result.reserveCapacity(key.components.count * 4)

        for idx in key.components.indices {
            if idx != key.components.startIndex {
                result.append(Self.Separator)
            }

            switch key.components[idx] {
            case .wildcard:
                result.append(Self.Wildcard)
            case .globstar:
                result.append(Self.Globstar)
            case let .segment(identifier):
                result.appendEscaped(identifier)
            }
        }

        self = result
    }

    private mutating func appendEscaped(_ string: String) {
        // Fast path: most identifiers contain no special characters.
        let needsEscaping = string.utf8.contains {
            $0 == UInt8(ascii: "\\") || $0 == UInt8(ascii: "*") || $0 == UInt8(ascii: "/")
        }

        guard needsEscaping else {
            append(string)
            return
        }

        for char in string {
            switch char {
            case "\\":
                append("\\\\")
            case "*":
                append("\\*")
            case "/":
                append("\\/")
            default:
                append(char)
            }
        }
    }
}
