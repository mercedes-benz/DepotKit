// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

@testable import DepotKit

extension Depot {
    /// Creates a depot backed by a unique temporary directory (for testing).
    static func temporary(
        memoryCache: DepotConfiguration.MemoryCacheCapacity = .disabled,
    ) -> Depot {
        Depot(
            configuration: .init(
                directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                memoryCache: memoryCache,
            ),
        )
    }

    /// Creates a depot backed by a unique temporary directory with a controllable clock (for testing).
    static func temporary(
        memoryCache: DepotConfiguration.MemoryCacheCapacity = .disabled,
        clock: any DepotClock,
    ) -> Depot {
        Depot(
            configuration: .init(
                directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                memoryCache: memoryCache,
            ),
            overrides: .init(clock: clock),
        )
    }
}

/// A controllable clock for deterministic TTL testing.
final class MockClock: DepotClock, Sendable {
    private let _now: OSAllocatedUnfairLock<Date>

    init(now: Date = Date()) {
        _now = OSAllocatedUnfairLock(initialState: now)
    }

    func now() -> Date { _now.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        _now.withLock { $0 = $0.addingTimeInterval(interval) }
    }

    func set(_ date: Date) {
        _now.withLock { $0 = date }
    }
}
