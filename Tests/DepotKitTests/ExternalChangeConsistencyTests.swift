// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

// MARK: - Helpers

/// Blocks the next decode on the thread that armed it until the test releases it.
///
/// Decodes on other threads pass, so an observer re-read (which runs on the cooperative pool)
/// can neither take the place of the paused read nor block a pool thread.
private final class DecodeGate: Sendable {
    private let armedThread = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    private static func currentThreadID() -> UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }

    func armForCurrentThread() {
        armedThread.withLock { $0 = Self.currentThreadID() }
    }

    func blockIfArmed() {
        let threadID = Self.currentThreadID()
        let shouldBlock = armedThread.withLock { armedThread in
            guard armedThread == threadID else {
                return false
            }
            armedThread = nil
            return true
        }
        guard shouldBlock else {
            return
        }
        entered.signal()
        release.wait()
    }
}

/// JSON coder for `Int` whose decode can be paused by a ``DecodeGate`` after the bytes were decoded.
private struct GatedIntCoder: Coder {
    let gate: DecodeGate

    func encode(_ value: Int) throws -> Data {
        try JSONEncoder().encode(value)
    }

    func decode(_ data: Data) throws -> Int {
        let value = try JSONDecoder().decode(Int.self, from: data)
        gate.blockIfArmed()
        return value
    }
}

/// Runs `work` on a dedicated thread (not the cooperative pool) and signals the returned semaphore when done.
private func runOnThread(_ work: @escaping @Sendable () -> Void) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        work()
        done.signal()
    }
    return done
}

/// Returns the first value emitted by `stream` that satisfies `predicate`, or `nil` after `timeout`.
private func firstValue<V: Sendable & Equatable>(
    in stream: AsyncStream<Result<V?, Error>>,
    timeout: Duration = testWaitTimeout,
    where predicate: @escaping @Sendable (V?) -> Bool,
) async -> V?? {
    await withTaskGroup(of: V??.self) { group in
        group.addTask {
            for await result in stream {
                if case let .success(value) = result, predicate(value) {
                    return .some(value)
                }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private func multiProcessConfiguration(_ url: URL, cache: Bool = true) -> DepotConfiguration {
    .init(
        directoryURL: url,
        enableMultiProcessSupport: true,
        memoryCache: cache ? .default : .disabled,
    )
}

private func setModificationDate(_ date: Date, for key: some DistinctKeyProtocol, in depot: Depot) throws {
    var resourceValues = URLResourceValues()
    resourceValues.contentModificationDate = date
    var fileURL = try depot.fileURL(for: key)
    try fileURL.setResourceValues(resourceValues)
}

private func modificationDate(for key: some DistinctKeyProtocol, in depot: Depot) throws -> Date? {
    let fileURL = try depot.fileURL(for: key)
    return try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))[.modificationDate]
        as? Date
}

// MARK: - Invalidation vs. cache population

@Suite("External-change invalidation vs. cache population", .offCooperativePool)
struct ExternalChangeCacheRaceTests {
    @Test("an in-flight decode of old bytes cannot re-cache a stale value after the external-change check")
    func inFlightDecodeDoesNotRecacheStaleValue() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let gate = DecodeGate()
        let depotA = Depot(configuration: multiProcessConfiguration(url))
        let depotB = Depot(configuration: multiProcessConfiguration(url))
        let keyA = depotA.register(keyPath: "value", coder: GatedIntCoder(gate: gate).eraseToAnyCoder())
        let keyB = depotB.register(keyPath: "value", coder: .json() as AnyCoder<Int>)

        try await depotB.set(value: 1, for: keyB)
        try await depotA.checkForExternalChanges()
        // Observe only from here on, so that no observer re-read of the old value is in flight (or
        // cached) when the interleaving's read decodes it.
        let stream = depotA.values(for: keyA, initialValue: false)

        // The interleaving blocks while it waits for the paused read; keep that off the cooperative pool.
        let interleaving = try await onDedicatedThread {
            try Self.runInterleaving(depotA: depotA, depotB: depotB, keyA: keyA, keyB: keyB, gate: gate)
        }
        #expect(interleaving.readFinished)
        #expect(interleaving.checkFinished, "checkForExternalChanges deadlocked")
        #expect(interleaving.readValue == 1)

        // Reads and observers converge on the replacement without manual cache clearing.
        #expect(try await depotA.get(valueFor: keyA) == 2)
        try await depotA.checkForExternalChanges()
        #expect(try await depotA.get(valueFor: keyA) == 2)

        let observed = await firstValue(in: stream) { $0 == 2 }
        #expect(observed == .some(2))
    }

    /// Runs the stale re-cache interleaving and returns the value produced by the paused read and whether
    /// the read and the concurrent check finished in time.
    private static func runInterleaving(
        depotA: Depot,
        depotB: Depot,
        keyA: TypedDistinctKey<Int>,
        keyB: TypedDistinctKey<Int>,
        gate: DecodeGate,
    ) throws -> (readValue: Int?, readFinished: Bool, checkFinished: Bool) {
        // 1. Depot A loads the old bytes and pauses inside decoding.
        let readValue = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let readDone = runOnThread {
            gate.armForCurrentThread()
            let value = try? depotA.get(valueFor: keyA)
            readValue.withLock { $0 = value }
        }
        gate.entered.wait()

        // 2. Depot B writes a replacement value.
        try depotB.set(value: 2, for: keyB)

        // 3. Depot A checks for external changes while its decode is still paused.
        let checkDone = runOnThread {
            try? depotA.checkForExternalChanges()
        }
        // Without coordination the check completes right away; with coordination it waits for the read.
        let checkFinishedEarly = checkDone.wait(timeout: .now() + .milliseconds(500)) == .success

        // 4. The paused decode resumes and finishes with the old value.
        gate.release.signal()
        let readFinished = readDone.wait(timeout: .now() + .seconds(30)) == .success
        let checkFinished = checkFinishedEarly || checkDone.wait(timeout: .now() + .seconds(30)) == .success
        return (readValue.withLock { $0 }, readFinished, checkFinished)
    }

    @Test("concurrent checks, reads, and writes converge without deadlock")
    func concurrentChecksAndReadsConverge() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depotA = Depot(configuration: multiProcessConfiguration(url))
        let depotB = Depot(configuration: multiProcessConfiguration(url))

        let keyCount = 4
        let keysA = (0..<keyCount).map { depotA.register(keyPath: "k\($0)", coder: .json() as AnyCoder<Int>) }
        let keysB = (0..<keyCount).map { depotB.register(keyPath: "k\($0)", coder: .json() as AnyCoder<Int>) }
        let localKey = depotA.register(keyPath: "local", coder: .json() as AnyCoder<Int>)

        let iterations = 60
        let writerFinished = OSAllocatedUnfairLock(initialState: false)
        var workers = [DispatchSemaphore]()

        // Readers on depot A
        for _ in 0..<3 {
            workers.append(
                runOnThread {
                    while !writerFinished.withLock({ $0 }) {
                        for key in keysA {
                            _ = try? depotA.get(valueFor: key)
                        }
                        _ = try? depotA.get(valuesFor: Key.from("*", as: Int.self))
                    }
                }
            )
        }

        // Concurrent external-change checks on depot A
        for _ in 0..<2 {
            workers.append(
                runOnThread {
                    while !writerFinished.withLock({ $0 }) {
                        try? depotA.checkForExternalChanges()
                    }
                }
            )
        }

        // Local writes on depot A (exercise lock ordering with checks)
        workers.append(
            runOnThread {
                var value = 0
                while !writerFinished.withLock({ $0 }) {
                    value += 1
                    try? depotA.set(value: value, for: localKey)
                }
            }
        )

        // External writer (depot B)
        let writerDone = runOnThread {
            for iteration in 1...iterations {
                for key in keysB {
                    try? depotB.set(value: iteration, for: key)
                }
            }
            writerFinished.withLock { $0 = true }
        }

        // Wait on a dedicated thread so the waits do not occupy the cooperative pool.
        let writerFinishedInTime = await onDedicatedThread {
            writerDone.wait(timeout: .now() + .seconds(120)) == .success
        }
        #expect(writerFinishedInTime, "writer did not finish (deadlock?)")
        writerFinished.withLock { $0 = true }
        let workerSemaphores = workers
        let unfinishedWorkers = await onDedicatedThread {
            workerSemaphores.filter { $0.wait(timeout: .now() + .seconds(60)) != .success }.count
        }
        #expect(unfinishedWorkers == 0, "\(unfinishedWorkers) workers did not finish (deadlock?)")

        try await depotA.checkForExternalChanges()
        for key in keysA {
            #expect(try await depotA.get(valueFor: key) == iterations)
        }
    }
}

// MARK: - Arbitrary modification dates

@Suite("External-change detection with arbitrary modification dates", .offCooperativePool)
struct ExternalChangeTimestampTests {
    @Test("tracker treats any differing modification date as a change")
    func trackerDetectsOlderAndNewerDates() {
        let tracker = DepotChangeTracker()
        tracker.setModificationDates([
            Key.from("older"): Date(timeIntervalSince1970: 100),
            Key.from("newer"): Date(timeIntervalSince1970: 100),
            Key.from("same"): Date(timeIntervalSince1970: 100),
        ])

        let diff = tracker.setModificationDates([
            Key.from("older"): Date(timeIntervalSince1970: 50),
            Key.from("newer"): Date(timeIntervalSince1970: 150),
            Key.from("same"): Date(timeIntervalSince1970: 100),
        ])

        #expect(diff.modified == [Key.from("older"), Key.from("newer")])
        #expect(diff.removed.isEmpty)
    }

    @Test(
        "replacement with an older or newer modification date invalidates the cache and notifies observers",
        arguments: [-3600.0, 3600.0],
    )
    func replacementWithDifferentTimestampIsDetected(offset: TimeInterval) async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depotA = Depot(configuration: multiProcessConfiguration(url))
        let depotB = Depot(configuration: multiProcessConfiguration(url))
        let keyA = depotA.register(keyPath: "value", coder: .json() as AnyCoder<Int>)
        let keyB = depotB.register(keyPath: "value", coder: .json() as AnyCoder<Int>)

        try await depotB.set(value: 1, for: keyB)
        try await depotA.checkForExternalChanges()
        #expect(try await depotA.get(valueFor: keyA) == 1)  // cached

        let originalDate = try #require(try modificationDate(for: keyA, in: depotA))
        let stream = depotA.values(for: keyA, initialValue: false)

        try await depotB.set(value: 2, for: keyB)
        try setModificationDate(originalDate.addingTimeInterval(offset), for: keyB, in: depotB)

        try await depotA.checkForExternalChanges()
        #expect(try await depotA.get(valueFor: keyA) == 2)

        let observed = await firstValue(in: stream) { $0 == 2 }
        #expect(observed == .some(2))
    }

    @Test("unchanged files and local writes do not produce spurious invalidations or notifications")
    func unchangedTimestampsProduceNoUpdates() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(configuration: multiProcessConfiguration(url))
        let key = depot.register(keyPath: "value", coder: .json() as AnyCoder<Int>)

        try await depot.set(value: 1, for: key)
        await depot.waitForPendingObservations()

        let notifications = OSAllocatedUnfairLock(initialState: 0)
        let stream = depot.values(for: key, initialValue: false)
        let collector = Task {
            for await _ in stream {
                notifications.withLock { $0 += 1 }
            }
        }

        try await depot.checkForExternalChanges()
        try await depot.checkForExternalChanges()
        await depot.waitForPendingObservations()

        let lookup: DepotMemoryCache.CacheLookupResult<Int> = try #require(depot.memoryCache).lookup(
            valueFor: DistinctKey(key),
            at: Date(),
        )
        guard case .hit(1) = lookup else {
            Issue.record("Expected the cached value to survive an unchanged check, got \(lookup)")
            return
        }
        #expect(notifications.withLock { $0 } == 0)
        collector.cancel()
    }
}

// MARK: - Debounced automatic checks

#if os(macOS)

/// A debounce sleep that only finishes when the test releases it and honors task cancellation.
private final class ControlledSleeper: Sendable {
    private struct State {
        var nextID = 0
        var pending = [Int: CheckedContinuation<Void, Error>]()
        var cancelled = Set<Int>()
        var durations = [Duration]()
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var pendingCount: Int { state.withLock { $0.pending.count } }
    var cancelledCount: Int { state.withLock { $0.cancelled.count } }
    var durations: [Duration] { state.withLock { $0.durations } }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            state.durations.append(duration)
            return state.nextID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = state.withLock { state -> Bool in
                    if state.cancelled.contains(id) || Task.isCancelled {
                        state.cancelled.insert(id)
                        return true
                    }
                    state.pending[id] = continuation
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.cancelled.insert(id)
                return state.pending.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func releaseAll() {
        let continuations = state.withLock { state in
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class DebounceProbe: Sendable {
    let sleeper = ControlledSleeper()
    private let tasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
    private let checks = OSAllocatedUnfairLock(initialState: 0)

    var scheduledTasks: [Task<Void, Never>] { tasks.withLock { $0 } }
    var checkCount: Int { checks.withLock { $0 } }

    var hooks: Depot.TestHooks {
        var hooks = Depot.TestHooks()
        hooks.debounceSleep = { [sleeper] in try await sleeper.sleep(for: $0) }
        hooks.didScheduleDebounceTask = { [tasks] task in tasks.withLock { $0.append(task) } }
        hooks.externalChangesCheck = { [checks] depot in
            checks.withLock { $0 += 1 }
            try await depot.checkForExternalChanges()
        }
        return hooks
    }

    func makeDepot() -> Depot {
        Depot(
            configuration: multiProcessConfiguration(
                FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
            ),
            overrides: .init(testHooks: hooks),
        )
    }
}

@Suite("Debounced automatic external-change checks", .offCooperativePool)
struct ExternalChangeDebounceTests {
    @Test("a burst of signals produces exactly one check after the final debounce interval")
    func burstProducesSingleCheck() async throws {
        let probe = DebounceProbe()
        let depot = probe.makeDepot()
        try depot.automaticallyCheckForExternalChanges(debounceInterval: 5)

        depot.externalChangesDetected?.emit()
        depot.externalChangesDetected?.emit()
        depot.externalChangesDetected?.emit()

        let tasks = probe.scheduledTasks
        try #require(tasks.count == 3)

        // Canceled delays finish without scanning.
        await tasks[0].value
        await tasks[1].value
        #expect(probe.checkCount == 0)
        #expect(probe.sleeper.cancelledCount == 2)

        // The final delay is still pending; no check has run yet.
        #expect(await waitUntil { probe.sleeper.pendingCount == 1 })
        #expect(probe.checkCount == 0)

        probe.sleeper.releaseAll()
        await tasks[2].value
        #expect(probe.checkCount == 1)
        #expect(probe.sleeper.durations.allSatisfy { $0 == .seconds(5) })
    }

    @Test("tearing down the depot cancels a pending debounce without scanning")
    func teardownCancelsPendingDebounce() async throws {
        let probe = DebounceProbe()
        var depot: Depot? = probe.makeDepot()
        try depot?.automaticallyCheckForExternalChanges(debounceInterval: 5)

        depot?.externalChangesDetected?.emit()
        let task = try #require(probe.scheduledTasks.first)
        #expect(await waitUntil { probe.sleeper.pendingCount == 1 })

        weak let weakDepot = depot
        depot = nil
        #expect(weakDepot == nil, "a pending debounce must not keep the depot alive")

        await task.value
        #expect(probe.sleeper.cancelledCount == 1)
        #expect(probe.checkCount == 0)
    }

    @Test("repeated registration does not duplicate debounced checks")
    func repeatedRegistrationSchedulesOnce() async throws {
        let probe = DebounceProbe()
        let depot = probe.makeDepot()
        try depot.automaticallyCheckForExternalChanges(debounceInterval: 5)
        try depot.automaticallyCheckForExternalChanges(debounceInterval: 5)

        depot.externalChangesDetected?.emit()
        depot.externalChangesDetected?.emit()

        let tasks = probe.scheduledTasks
        try #require(tasks.count == 2)

        await tasks[0].value
        #expect(probe.checkCount == 0)

        #expect(await waitUntil { probe.sleeper.pendingCount == 1 })
        probe.sleeper.releaseAll()
        await tasks[1].value
        #expect(probe.checkCount == 1)

        // A later signal after the burst schedules exactly one more check.
        depot.externalChangesDetected?.emit()
        let laterTask = try #require(probe.scheduledTasks.last)
        #expect(await waitUntil { probe.sleeper.pendingCount == 1 })
        probe.sleeper.releaseAll()
        await laterTask.value
        #expect(probe.checkCount == 2)
    }
}

#endif
