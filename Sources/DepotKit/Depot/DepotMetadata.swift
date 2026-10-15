// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Note: Only to be used by ``Depot``!
struct DepotMetadata: Equatable, Codable, Sendable {
    // MARK: Properties

    let version: String
    let createdAt: Date

    // MARK: - Init

    init(version: String = "1", createdAt: Date = Date()) {
        self.version = version
        self.createdAt = createdAt
    }
}
