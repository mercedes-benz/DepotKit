// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct AsyncStreamCancellationTests {
    @Test("cancelling task cleans up observer")
    func cancelCleansUpObserver() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "cancel-test", coder: .json() as AnyCoder<String>)

        let task = Task {
            for await _ in depot.values(for: key, initialValue: false) {}
        }

        // Give time for subscription
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()
        await task.value

        // After cancellation, setting a value should not crash or leak
        try await depot.set(value: "after-cancel", for: key)
        await depot.waitForPendingObservations()
    }

    @Test("multiple observers for same key all receive updates")
    func multipleObservers() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "multi", coder: .json() as AnyCoder<Int>)

        let received1 = OSAllocatedUnfairLock(initialState: [Int]())
        let received2 = OSAllocatedUnfairLock(initialState: [Int]())

        let task1 = Task {
            for await case .success(let v?) in depot.values(for: key, initialValue: false) {
                received1.withLock { $0.append(v) }
            }
        }
        let task2 = Task {
            for await case .success(let v?) in depot.values(for: key, initialValue: false) {
                received2.withLock { $0.append(v) }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        try await depot.set(value: 99, for: key)
        await depot.waitForPendingObservations()
        try await Task.sleep(for: .milliseconds(50))

        task1.cancel()
        task2.cancel()
        await task1.value
        await task2.value

        #expect(received1.withLock { $0 }.last == 99)
        #expect(received2.withLock { $0 }.last == 99)
    }
}
