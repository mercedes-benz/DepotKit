// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Regression tests: observer notifications must be delivered in
/// commit order so that observers never settle on a superseded value.
@Suite
struct ObserverCommitOrderTests {
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

    /// The mutation performed by the writer that is paused after its commit.
    enum FirstWriter: String, CaseIterable, Sendable {
        case set
        case transaction
    }

    /// The mutation that commits while the first writer is paused.
    enum SecondWriter: String, CaseIterable, Sendable {
        case set
        case setNil
        case remove
        case removePattern
        case transactionSet
        case transactionRemove

        var expectedValue: Int? {
            switch self {
            case .set, .transactionSet:
                2
            case .setNil, .remove, .removePattern, .transactionRemove:
                nil
            }
        }
    }

    /// Records the most recent observed value per observer kind.
    final class Recorder: Sendable {
        let single = OSAllocatedUnfairLock<Int??>(initialState: nil)
        let multi = OSAllocatedUnfairLock<[Int]?>(initialState: nil)
        let pattern = OSAllocatedUnfairLock<[Int]?>(initialState: nil)
        let available = OSAllocatedUnfairLock<[Int]?>(initialState: nil)
        let errors = OSAllocatedUnfairLock(initialState: 0)

        func record<T: Sendable>(_ result: Result<T, Error>, into lock: OSAllocatedUnfairLock<T?>) {
            switch result {
            case let .success(value):
                lock.withLock { $0 = value }
            case .failure:
                errors.withLock { $0 += 1 }
            }
        }
    }

    /// Pauses the first mutation that reaches the after-commit hook until resumed.
    final class CommitGate: Sendable {
        private let consumed = OSAllocatedUnfairLock(initialState: false)
        let reached = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)

        func hook() {
            let isFirst = consumed.withLock { consumed in
                defer { consumed = true }
                return !consumed
            }
            guard isFirst else {
                return
            }

            reached.signal()
            resume.wait()
        }
    }

    // MARK: - Helpers

    private static func pattern() -> TypedKey<Int> {
        Key.from("items" / .wildcard, as: Int.self)
    }

    private static func itemKey() -> TypedDistinctKey<Int> {
        Key.from("items" / "a", as: Int.self)
    }

    private static func observeAll(
        _ depot: Depot,
        recorder: Recorder,
    ) -> [any DepotCancellable] {
        let key = itemKey()
        return [
            depot.core.observe(
                valueFor: key,
                initialValue: true,
                update: { recorder.record($0, into: recorder.single) },
                in: depot
            ),
            depot.core.observe(
                valuesFor: TypedKey(key),
                initialValues: true,
                update: { recorder.record($0, into: recorder.multi) },
                in: depot
            ),
            depot.core.observe(
                valuesFor: pattern(),
                initialValues: true,
                update: { recorder.record($0, into: recorder.pattern) },
                in: depot
            ),
            depot.core.observe(
                availableValuesFor: TypedKey(key),
                initialValues: true,
                update: { result in
                    recorder.record(result.map { Array($0.keyedValues.values) }, into: recorder.available)
                },
                in: depot
            ),
        ]
    }

    private static func waitOnBackground(_ semaphore: DispatchSemaphore) async {
        await onDedicatedThread { semaphore.wait() }
    }

    private static func perform(_ writer: FirstWriter, value: Int, on depot: Depot) throws {
        let key = itemKey()
        switch writer {
        case .set:
            try depot.set(value: value, for: key)
        case .transaction:
            try depot.transaction { try $0.set(value: value, for: key) }
        }
    }

    private static func perform(_ writer: SecondWriter, on depot: Depot) throws {
        let key = itemKey()
        switch writer {
        case .set:
            try depot.set(value: 2, for: key)
        case .setNil:
            try depot.set(value: nil, for: key)
        case .remove:
            try depot.remove(valueFor: key)
        case .removePattern:
            try depot.remove(valuesFor: pattern())
        case .transactionSet:
            try depot.transaction { try $0.set(value: 2, for: key) }
        case .transactionRemove:
            try depot.transaction { try $0.remove(valueFor: key) }
        }
    }

    private static func expectObserved(
        _ recorder: Recorder,
        equal expected: Int?,
        on depot: Depot,
        _ context: Comment,
    ) throws {
        let stored = try depot.get(valueFor: itemKey())
        #expect(stored == expected, context)

        let expectedArray = expected.map { [$0] } ?? []
        #expect(recorder.single.withLock { $0 } == .some(stored), context)
        #expect(recorder.multi.withLock { $0 } == expectedArray, context)
        #expect(recorder.pattern.withLock { $0 } == expectedArray, context)
        #expect(recorder.available.withLock { $0 } == expectedArray, context)
        #expect(recorder.errors.withLock { $0 } == 0, context)
    }

    // MARK: - Controlled interleaving

    @Test(
        "observers end at the committed value when a writer pauses between commit and notification",
        arguments: StorageMode.allCases,
        FirstWriter.allCases,
    )
    func pausedWriterDoesNotOverwriteNewerNotification(mode: StorageMode, first: FirstWriter) async throws {
        for second in SecondWriter.allCases {
            try await runInterleaving(mode: mode, first: first, second: second)
        }
    }

    private func runInterleaving(mode: StorageMode, first: FirstWriter, second: SecondWriter) async throws {
        let depot = mode.makeDepot()
        defer {
            if let url = depot.configuration.directoryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        depot.register(key: Self.pattern(), coder: .json(Int.self))

        let recorder = Recorder()
        let cancellables = Self.observeAll(depot, recorder: recorder)
        defer {
            for cancellable in cancellables {
                cancellable.cancel()
            }
        }
        await depot.waitForPendingObservations()

        let gate = CommitGate()
        depot.core.setAfterCommitHook { gate.hook() }

        // Writer A commits value 1, then pauses before returning.
        let firstDone = DispatchSemaphore(value: 0)
        let firstError = OSAllocatedUnfairLock<String?>(initialState: nil)
        Thread.detachNewThread {
            do {
                try Self.perform(first, value: 1, on: depot)
            } catch {
                firstError.withLock { $0 = "\(error)" }
            }
            firstDone.signal()
        }
        await Self.waitOnBackground(gate.reached)

        // Writer B commits (and notifies) while A is paused.
        try Self.perform(second, on: depot)

        gate.resume.signal()
        await Self.waitOnBackground(firstDone)
        depot.core.setAfterCommitHook(nil)
        #expect(firstError.withLock { $0 } == nil)

        await depot.waitForPendingObservations()

        try Self.expectObserved(
            recorder,
            equal: second.expectedValue,
            on: depot,
            "mode=\(mode) first=\(first) second=\(second)",
        )
    }

    // MARK: - Subscription boundary

    @Test(
        "observers registered after a write returns do not receive that write",
        arguments: StorageMode.allCases,
    )
    func lateObserverDoesNotReceiveEarlierWrite(mode: StorageMode) async throws {
        let depot = mode.makeDepot()
        defer {
            if let url = depot.configuration.directoryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        depot.register(key: Self.pattern(), coder: .json(Int.self))

        // An existing observer keeps the notification fast path active.
        let earlyRecorder = Recorder()
        let early = Self.observeAll(depot, recorder: earlyRecorder)
        defer {
            for cancellable in early {
                cancellable.cancel()
            }
        }

        let deliveries = OSAllocatedUnfairLock(initialState: 0)
        for value in 1...50 {
            try await depot.set(value: value, for: Self.itemKey())
            let late = depot.core.observe(
                valueFor: Self.itemKey(),
                initialValue: false,
                update: { _ in deliveries.withLock { $0 += 1 } },
                in: depot
            )
            await depot.waitForPendingObservations()
            late.cancel()
        }

        #expect(deliveries.withLock { $0 } == 0)
        try Self.expectObserved(earlyRecorder, equal: 50, on: depot, "mode=\(mode)")
    }

    // MARK: - Concurrent stress

    @Test(
        "observers end at the committed value after concurrent writes, removals and transactions",
        arguments: StorageMode.allCases,
    )
    func concurrentMutationsSettleOnCommittedValue(mode: StorageMode) async throws {
        let rounds = mode == .memory ? 40 : 8
        let writers = mode == .memory ? 8 : 4
        let operationsPerWriter = mode == .memory ? 60 : 20

        for round in 0..<rounds {
            let depot = mode.makeDepot()
            defer {
                if let url = depot.configuration.directoryURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            depot.register(key: Self.pattern(), coder: .json(Int.self))

            let recorder = Recorder()
            let cancellables = Self.observeAll(depot, recorder: recorder)
            defer {
                for cancellable in cancellables {
                    cancellable.cancel()
                }
            }

            let failures = OSAllocatedUnfairLock(initialState: [String]())
            let key = Self.itemKey()
            // `concurrentPerform` blocks its caller; keep it off the cooperative pool.
            await onDedicatedThread {
                DispatchQueue.concurrentPerform(iterations: writers) { writer in
                    for operation in 0..<operationsPerWriter {
                        let value = round * 1_000_000 + writer * 10000 + operation
                        do {
                            switch (writer + operation) % 6 {
                            case 0, 1, 2:
                                try depot.set(value: value, for: key)
                            case 3:
                                try depot.remove(valueFor: key)
                            case 4:
                                try depot.transaction { try $0.set(value: value, for: key) }
                            default:
                                if operation % 2 == 0 {
                                    try depot.remove(valuesFor: Self.pattern())
                                } else {
                                    try depot.transaction { try $0.remove(valueFor: key) }
                                }
                            }
                        } catch {
                            failures.withLock { $0.append("\(error)") }
                        }
                    }
                }
            }

            #expect(failures.withLock { $0 }.isEmpty)

            await depot.waitForPendingObservations()

            let stored = try await depot.get(valueFor: key)
            try Self.expectObserved(recorder, equal: stored, on: depot, "mode=\(mode) round=\(round)")
        }
    }
}
