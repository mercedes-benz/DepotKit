// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

@testable import DepotKit

/// Serializes tests that replace the process-wide `DepotKitLogging.sink`.
///
/// Tests run in parallel, so a test that installs a capturing sink must not overlap with another
/// test that replaces the sink. Depots in unrelated tests still log concurrently, so capturing
/// tests must only evaluate messages they emitted themselves.
enum LogSinkTestLock {
    private static let semaphore = AsyncSemaphore(value: 1)

    /// Runs `body` while no other test replaces the sink, and restores the previous sink afterwards.
    static func withExclusiveSink<T>(_ body: () async throws -> T) async throws -> T {
        try await semaphore.wait()
        defer { semaphore.signal() }

        let previous = DepotKitLogging.sink
        defer { DepotKitLogging.sink = previous }

        return try await body()
    }
}
