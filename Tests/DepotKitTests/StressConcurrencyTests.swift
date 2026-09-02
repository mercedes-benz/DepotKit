// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct StressConcurrencyTests {
    @Test("cancelling queued async work does not execute it")
    func cancellingQueuedAsyncWorkDoesNotExecuteIt() async throws {
        let depotURL = try DepotConfiguration.directoryURL(
            in: .temporary,
            name: "StressCancelTest-\(UUID().uuidString)",
        )
        defer { try? FileManager.default.removeItem(at: depotURL) }

        let depot = Depot(
            configuration: .init(directoryURL: depotURL, memoryCache: .disabled),
            maximumConcurrentTasks: 1,
        )

        let started = OSAllocatedUnfairLock(initialState: false)
        let executed = OSAllocatedUnfairLock(initialState: 0)
        let gate = DispatchSemaphore(value: 0)

        let first = Task {
            try await depot.withSemaphore {
                executed.withLock { $0 += 1 }
                started.withLock { $0 = true }
                gate.wait()
            }
        }

        #expect(await waitUntil(timeout: .seconds(3)) { started.withLock { $0 } })

        let cancelled = Task {
            try await depot.withSemaphore {
                executed.withLock { $0 += 1 }
            }
        }

        cancelled.cancel()
        #expect(cancelled.isCancelled == true)

        let third = Task {
            try await depot.withSemaphore {
                executed.withLock { $0 += 1 }
            }
        }

        gate.signal()

        try await first.value
        try await third.value

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        #expect(executed.withLock { $0 } == 2)
    }

    @Test("Depot concurrent read/write is stable")
    func depotConcurrentReadWriteIsStable() async throws {
        let depotURL = try DepotConfiguration.directoryURL(
            in: .temporary,
            name: "DepotStress-\(UUID().uuidString)",
        )
        defer { try? FileManager.default.removeItem(at: depotURL) }

        let configuration = DepotConfiguration(directoryURL: depotURL, memoryCache: .disabled)
        let depot = Depot(configuration: configuration, maximumConcurrentTasks: 8)

        _ = depot.register(key: Key.from("values" / .wildcard), coder: .data(String.self))

        let keyCount = 50
        let keys = (0..<keyCount).map { i in
            Key.from("values" / i, as: String.self)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, key) in keys.enumerated() {
                group.addTask {
                    try await depot.set(value: "\(i)", for: key)
                }
            }

            // Concurrent reads while writes are happening.
            for _ in 0..<200 {
                group.addTask {
                    let idx = Int.random(in: 0..<keyCount)
                    _ = try await depot.get(valueFor: keys[idx])
                }
            }

            try await group.waitForAll()
        }

        let wildcardKey = Key.from("values" / .wildcard, as: String.self)
        let values = try await depot.get(valuesFor: wildcardKey)

        #expect(Set(values) == Set((0..<keyCount).map { "\($0)" }))
    }

    @Test("concurrent writes to the same key produce a consistent final value")
    func concurrentWritesToSameKeyProduceConsistentFinalValue() async throws {
        let depotURL = try DepotConfiguration.directoryURL(
            in: .temporary,
            name: "StressSameKey-\(UUID().uuidString)",
        )
        defer { try? FileManager.default.removeItem(at: depotURL) }

        let depot = Depot(
            configuration: .init(directoryURL: depotURL, memoryCache: .disabled),
            maximumConcurrentTasks: 8,
        )

        let key = depot.register(key: Key.from("counter"), coder: .data(Int.self))

        let writeCount = 100
        let lastValue = writeCount - 1

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<writeCount {
                group.addTask {
                    try await depot.set(value: i, for: key)
                }
            }
            try await group.waitForAll()
        }

        let finalValue = try await depot.get(valueFor: key)
        // The final value must be one of the written values (not nil, not corrupted).
        #expect(finalValue != nil, "Final value must not be nil after concurrent writes")
        if let value = finalValue {
            #expect((0..<writeCount).contains(value), "Final value \(value) must be one of the written values")
        }

        // Additionally verify the same key can still be read back deterministically
        // when written serially after the concurrent storm.
        try await depot.set(value: lastValue, for: key)
        #expect(try await depot.get(valueFor: key) == lastValue)
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(10),
    _ predicate: @escaping @Sendable () -> Bool,
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if predicate() {
            return true
        }
        try? await Task.sleep(for: pollInterval)
    }

    return predicate()
}
