// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

extension Collection<KeyComponent> {
    @inlinable
    @inline(__always)
    func containsPattern() -> Bool {
        contains { $0.isPattern }
    }

    /// Validates only non-empty identifiers (skips wildcard checks for distinct expressions).
    @usableFromInline
    func assertValidIdentifiers() {
        precondition(!isEmpty, "A key must have at least one component.")
        for component in self {
            if case let .segment(identifier) = component {
                precondition(!identifier.isEmpty, "A key component must not be empty.")
            }
        }
    }

    @inlinable
    @inline(__always)
    func assertValidKeyComponents() {
        precondition(!isEmpty, "A key must have at least one component.")

        var previous: KeyComponent?
        for component in self {
            switch component {
            case let .segment(identifier):
                precondition(!identifier.isEmpty, "A key component must not be empty.")
            case .wildcard:
                precondition(previous != .wildcard, "A key must not contain consecutive wildcards.")
            case .globstar:
                precondition(previous != .globstar, "A key must not contain consecutive globstars.")
            }
            previous = component
        }
    }
}
