// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Regression tests: every AsyncStream handle tracked by `DepotCore`
/// must have its own stable identity so teardown finishes every live stream.
@Suite
struct StreamHandleIdentityTests {
    enum StorageMode: String, CaseIterable, Sendable {
        case memory
        case file

        func makeDepot() -> Depot {
            switch self {
            case .memory:
                Depot()
            case .file:
                Depot.temporary()
            }
        }
    }

    final class WeakDepot: @unchecked Sendable {
        weak var value: Depot?
    }

    /// Allocates and drops short-lived objects so freed addresses get reused.
    private static func churnAllocations() {
        var objects = [NSObject]()
        for _ in 0..<16 {
            objects.append(NSObject())
        }
        objects.removeAll()
        _ = [Int](repeating: 0, count: 32)
    }

    @Test("stream handles for distinct continuations are distinct")
    func handlesHaveDistinctIdentities() {
        let count = 2000
        var continuations = [Any]()
        var handles = Set<DepotCore.AnyStreamHandle>()

        for index in 0..<count {
            let handle: DepotCore.AnyStreamHandle
            switch index % 3 {
            case 0:
                let (_, continuation) = AsyncStream<Result<Int?, Error>>.makeStream()
                continuations.append(continuation)
                handle = DepotCore.AnyStreamHandle(continuation)
            case 1:
                let (_, continuation) = AsyncStream<Result<[Int], Error>>.makeStream()
                continuations.append(continuation)
                handle = DepotCore.AnyStreamHandle(continuation)
            default:
                let (_, continuation) = AsyncStream<Result<AvailableValuesResult<Int>, Error>>.makeStream()
                continuations.append(continuation)
                handle = DepotCore.AnyStreamHandle(continuation)
            }
            handles.insert(handle)
            Self.churnAllocations()
        }

        #expect(handles.count == count)
        #expect(continuations.count == count)
    }

    @Test("a stream handle is equal only to itself")
    func handleEqualityIsIdentity() {
        let (_, continuation) = AsyncStream<Int>.makeStream()
        let first = DepotCore.AnyStreamHandle(continuation)
        let second = DepotCore.AnyStreamHandle(continuation)

        #expect(first == first)
        #expect(first != second)
        #expect(Set([first, second, first]).count == 2)
    }

    @Test(
        "depot teardown finishes all remaining streams after partial cancellation",
        arguments: StorageMode.allCases,
    )
    func teardownFinishesAllRemainingStreams(mode: StorageMode) async throws {
        let streamsPerVariant = 150
        let finished = OSAllocatedUnfairLock(initialState: Set<Int>())
        var tasks = [Int: Task<Void, Never>]()
        let weakDepot = WeakDepot()
        var directoryURL: URL?
        defer {
            if let directoryURL {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        do {
            let depot = mode.makeDepot()
            weakDepot.value = depot
            directoryURL = depot.configuration.directoryURL

            let pattern = depot.register(keyPath: "items" / .wildcard, coder: .json(Int.self))
            let item = Key.from("items" / "a", as: Int.self)
            try await depot.set(value: 1, for: item)

            for index in 0..<streamsPerVariant * 3 {
                let task: Task<Void, Never>
                switch index % 3 {
                case 0:
                    let stream = depot.values(for: item, initialValue: false)
                    task = Task {
                        for await _ in stream {}
                        finished.withLock { _ = $0.insert(index) }
                    }
                case 1:
                    let stream = depot.values(for: pattern, initialValues: false)
                    task = Task {
                        for await _ in stream {}
                        finished.withLock { _ = $0.insert(index) }
                    }
                default:
                    let stream = depot.availableValues(for: pattern, initialValues: false)
                    task = Task {
                        for await _ in stream {}
                        finished.withLock { _ = $0.insert(index) }
                    }
                }
                tasks[index] = task
                Self.churnAllocations()
            }

            #expect(depot.core.activeStreamCount == streamsPerVariant * 3)

            // Cancel a subset spanning all stream variants.
            let cancelled = Set(tasks.keys.filter { $0 % 4 == 0 })
            for index in cancelled {
                tasks[index]?.cancel()
            }
            for index in cancelled {
                await tasks[index]?.value
            }

            #expect(depot.core.activeStreamCount == tasks.count - cancelled.count)

            // Deliver at least one update through the surviving streams.
            try await depot.set(value: 2, for: item)
            await depot.waitForPendingObservations()
        }

        // Releasing the last reference tears down the depot and its core.
        #expect(await waitUntil { weakDepot.value == nil })

        let expectedCount = tasks.count
        let allFinished = await waitUntil {
            finished.withLock { $0.count } == expectedCount
        }
        #expect(allFinished, "\(expectedCount - finished.withLock { $0.count }) streams never finished")

        // Do not leak unfinished consumers into other tests.
        for task in tasks.values {
            task.cancel()
        }
    }
}
