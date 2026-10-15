// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Metadata associated with a stored value in a ``Depot``.
///
/// Access via ``Depot/metadata(for:)-3rcvg`` to inspect when a value was last
/// written or when it will expire. Returns `nil` for keys that have no
/// stored value or whose value has already expired.
public struct ValueMetadata: Sendable, Equatable, Hashable {
    /// The date at which the value was last written.
    public let modifiedAt: Date

    /// The date at which the value expires, or `nil` if the value has no expiry.
    public let expiresAt: Date?

    /// Creates a new metadata instance.
    public init(modifiedAt: Date, expiresAt: Date?) {
        self.modifiedAt = modifiedAt
        self.expiresAt = expiresAt
    }
}
