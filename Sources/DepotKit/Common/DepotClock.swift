// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Provides the current wall-clock time for expiry calculations.
///
/// Wall clock, not monotonic — `expiresAt` is persisted as a Unix timestamp in the file header
/// and must remain meaningful across process restarts and reboots.
protocol DepotClock: Sendable {
    func now() -> Date
}

/// Default clock backed by `Date()`.
struct SystemClock: DepotClock {
    func now() -> Date { Date() }
}

extension Duration {
    /// Converts this duration to a `TimeInterval` (seconds as `Double`).
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
