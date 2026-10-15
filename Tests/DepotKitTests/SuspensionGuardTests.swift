// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// An activity provider whose activities the test grants, expires, or leaves without a grant.
private final class ControlledActivityProvider: ExpiringActivityProvider, @unchecked Sendable {
    enum Mode {
        /// Calls every activity's non-expired block right away.
        case grant
        /// Signals the expiration of every activity right away, before any grant: the system is
        /// about to suspend the process.
        case refuse
        /// Calls no block until the test calls `grant(_:)` or `expire(_:)`.
        case manual
    }

    private let condition = NSCondition()
    private var _mode: Mode
    private var blocks = [@Sendable (Bool) -> Void]()
    private var endedActivities = 0
    private var expirations = 0

    init(mode: Mode) {
        _mode = mode
    }

    var mode: Mode {
        get { condition.withLock { _mode } }
        set { condition.withLock { _mode = newValue } }
    }

    /// Blocks `performExpiringActivity` until released, if set.
    var startGate: Checkpoint? {
        get { condition.withLock { _startGate } }
        set { condition.withLock { _startGate = newValue } }
    }
    private var _startGate: Checkpoint?

    /// The number of activities started so far.
    var startedActivities: Int { condition.withLock { blocks.count } }

    /// The number of activities whose non-expired block returned.
    var ended: Int { condition.withLock { endedActivities } }

    func performExpiringActivity(reason: String, using block: @escaping @Sendable (Bool) -> Void) {
        let (mode, gate) = condition.withLock {
            blocks.append(block)
            return (_mode, _startGate)
        }
        gate?.pass()
        switch mode {
        case .grant:
            runGranted(block)
        case .refuse:
            Thread.detachNewThread { [self] in
                runExpired(block)
            }
        case .manual:
            break
        }
    }

    /// Calls the non-expired block of the activity with the given index on another thread.
    func grant(_ index: Int) {
        runGranted(condition.withLock { blocks[index] })
    }

    /// Announces the suspension to the activity with the given index and returns once the guard
    /// processed it.
    func expire(_ index: Int) {
        runExpired(condition.withLock { blocks[index] })
    }

    /// Waits until `count` non-expired blocks returned.
    func waitUntilEnded(_ count: Int) -> Bool {
        wait { $0.endedActivities >= count }
    }

    /// Waits until the guard processed `count` expirations.
    func waitUntilExpired(_ count: Int) -> Bool {
        wait { $0.expirations >= count }
    }

    private func wait(until predicate: (ControlledActivityProvider) -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 30)
        return condition.withLock {
            while !predicate(self) {
                guard condition.wait(until: deadline) else {
                    return false
                }
            }
            return true
        }
    }

    private func runGranted(_ block: @escaping @Sendable (Bool) -> Void) {
        Thread.detachNewThread { [self] in
            block(false)
            condition.withLock {
                endedActivities += 1
                condition.broadcast()
            }
        }
    }

    private func runExpired(_ block: @Sendable (Bool) -> Void) {
        block(true)
        condition.withLock {
            expirations += 1
            condition.broadcast()
        }
    }
}

/// Lets a critical section wait for the test, and the test wait for the section.
private final class Checkpoint: Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// Called by the section: signals that it got here and waits for `release()`.
    func pass() {
        reached.signal()
        released.wait()
    }

    func waitUntilReached() -> Bool {
        reached.wait(timeout: .now() + 30) == .success
    }

    func release() {
        released.signal()
    }
}

/// A clock that only advances when the test says so.
private final class ManualClock: Sendable {
    private let start = ContinuousClock.now
    private let elapsed = OSAllocatedUnfairLock(initialState: Duration.zero)

    var now: ContinuousClock.Instant { start.advanced(by: elapsed.withLock { $0 }) }

    func advance(by duration: Duration) {
        elapsed.withLock { $0 += duration }
    }
}

private func isSuspensionImminent(_ result: Result<Int, any Error>) -> Bool {
    if case .failure(DepotError.suspensionImminent) = result {
        return true
    }
    return false
}

@Suite("Keeping the process unsuspended during cross-process file access", .offCooperativePool)
struct SuspensionGuardTests {
    @Test("a granted activity runs the section and ends right after it")
    func grantedActivity() async throws {
        let provider = ControlledActivityProvider(mode: .grant)
        let suspensionGuard = SuspensionGuard(provider: provider, lingerInterval: .zero)

        let ended = try await onDedicatedThread {
            let value = try suspensionGuard.run { 42 }
            #expect(value == 42)
            return provider.waitUntilEnded(1)
        }
        #expect(ended)

        // The next section starts a new activity.
        let ranAgain = try await onDedicatedThread { try suspensionGuard.run { true } && provider.waitUntilEnded(2) }
        #expect(ranAgain)
        #expect(provider.startedActivities == 2)
    }

    @Test("sections that follow each other closely share an activity, which lingers after the last of them")
    func closelyFollowingSectionsShareActivity() async throws {
        let provider = ControlledActivityProvider(mode: .grant)
        let lingerInterval = Duration.milliseconds(500)
        let suspensionGuard = SuspensionGuard(provider: provider, lingerInterval: lingerInterval)

        let lingered = try await onDedicatedThread {
            _ = try suspensionGuard.run { 1 }
            _ = try suspensionGuard.run { 2 }
            let lastSectionEnded = ContinuousClock.now
            #expect(provider.startedActivities == 1)
            #expect(provider.waitUntilEnded(1))
            return lastSectionEnded.duration(to: .now)
        }
        #expect(lingered >= lingerInterval)

        let value = try await onDedicatedThread { try suspensionGuard.run { 3 } }
        #expect(value == 3)
        #expect(provider.startedActivities == 2)
    }

    @Test("sections never wait for the grant, and share the activity until its block runs")
    func sectionsDoNotWaitForGrant() async throws {
        let provider = ControlledActivityProvider(mode: .manual)
        let suspensionGuard = SuspensionGuard(provider: provider, lingerInterval: .zero)

        // The system never calls the block, like when sections occupy every thread of the pool.
        let sequential = try await onDedicatedThread {
            try (0..<3).map { index in try suspensionGuard.run { index } }
        }
        #expect(sequential == [0, 1, 2])
        let concurrent = OSAllocatedUnfairLock(initialState: 0)
        await concurrentlyOnDedicatedThreads(iterations: 16, threadCount: 8) { _ in
            if (try? suspensionGuard.run({ true })) == true {
                concurrent.withLock { $0 += 1 }
            }
        }
        #expect(concurrent.withLock { $0 } == 16)
        #expect(provider.startedActivities == 1, "until its block runs, the activity is in effect and shared")

        // The block returns right away: no section is running.
        provider.grant(0)
        #expect(await onDedicatedThread { provider.waitUntilEnded(1) })

        let value = try await onDedicatedThread { try suspensionGuard.run { 7 } }
        #expect(value == 7)
        #expect(provider.startedActivities == 2)
    }

    @Test("sections that join an activity being started wait only until the provider returned")
    func joinersWaitForStart() async throws {
        let provider = ControlledActivityProvider(mode: .manual)
        let gate = Checkpoint()
        provider.startGate = gate
        let suspensionGuard = SuspensionGuard(provider: provider)
        let secondRan = OSAllocatedUnfairLock(initialState: false)

        async let first = onDedicatedThread { try suspensionGuard.run { 1 } }
        #expect(await onDedicatedThread { gate.waitUntilReached() })
        async let second = onDedicatedThread {
            try suspensionGuard.run {
                secondRan.withLock { $0 = true }
                return 2
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!secondRan.withLock { $0 })

        gate.release()
        #expect(try await first == 1)
        #expect(try await second == 2)
        #expect(provider.startedActivities == 1)
    }

    @Test("an expiration before the grant lets running sections finish but refuses new sections")
    func expirationBeforeGrant() async throws {
        let provider = ControlledActivityProvider(mode: .manual)
        let clock = ManualClock()
        let suspensionGuard = SuspensionGuard(provider: provider, lingerInterval: .seconds(60), now: { clock.now })
        let checkpoint = Checkpoint()

        async let running: Int = onDedicatedThread {
            try suspensionGuard.run {
                checkpoint.pass()
                return try suspensionGuard.run { 1 }
            }
        }
        #expect(await onDedicatedThread { checkpoint.waitUntilReached() })

        await onDedicatedThread { provider.expire(0) }
        let refused = await onDedicatedThread { Result { try suspensionGuard.run { 2 } } }
        #expect(isSuspensionImminent(refused))

        checkpoint.release()
        #expect(try await running == 1)

        // A late block returns right away, without lingering.
        provider.grant(0)
        #expect(await onDedicatedThread { provider.waitUntilEnded(1) })

        clock.advance(by: SuspensionGuard.defaultBackOffInterval)
        provider.mode = .grant
        let value = try await onDedicatedThread { try suspensionGuard.run { 3 } }
        #expect(value == 3)
        #expect(provider.startedActivities == 2)
    }

    @Test("a section whose activity expires right away runs, and new sections are refused")
    func refusedActivity() async throws {
        let provider = ControlledActivityProvider(mode: .refuse)
        let clock = ManualClock()
        let suspensionGuard = SuspensionGuard(provider: provider, now: { clock.now })
        let ran = OSAllocatedUnfairLock(initialState: false)

        let first = try await onDedicatedThread { try suspensionGuard.run { 1 } }
        #expect(first == 1)
        #expect(await onDedicatedThread { provider.waitUntilExpired(1) })

        let result = await onDedicatedThread {
            Result { try suspensionGuard.run { ran.withLock { $0 = true } } }
        }
        #expect(throws: DepotError.suspensionImminent) { try result.get() }
        #expect(!ran.withLock { $0 })

        // Once the process may run again, sections run again.
        provider.mode = .grant
        clock.advance(by: SuspensionGuard.defaultBackOffInterval)
        let value = try await onDedicatedThread { try suspensionGuard.run { 7 } }
        #expect(value == 7)
        #expect(provider.startedActivities == 2)
    }

    @Test("an expiration during a section lets it finish but refuses new sections")
    func expirationDuringSection() async throws {
        let provider = ControlledActivityProvider(mode: .grant)
        let clock = ManualClock()
        let suspensionGuard = SuspensionGuard(provider: provider, lingerInterval: .seconds(60), now: { clock.now })
        let checkpoint = Checkpoint()

        async let running: Int = onDedicatedThread {
            try suspensionGuard.run {
                checkpoint.pass()
                // Nested access of the running section joins it despite the expiration.
                return try suspensionGuard.run { 1 }
            }
        }
        #expect(await onDedicatedThread { checkpoint.waitUntilReached() })

        await onDedicatedThread { provider.expire(0) }
        let refused = await onDedicatedThread { Result { try suspensionGuard.run { 2 } } }
        #expect(isSuspensionImminent(refused))
        #expect(provider.ended == 0, "the activity lasts until the running section finished")

        checkpoint.release()
        #expect(try await running == 1)
        // The activity ends right after the running section, without lingering.
        #expect(await onDedicatedThread { provider.waitUntilEnded(1) })

        // After the back-off, a new section asks the system again.
        clock.advance(by: SuspensionGuard.defaultBackOffInterval)
        let value = try await onDedicatedThread { try suspensionGuard.run { 3 } }
        #expect(value == 3)
        #expect(provider.startedActivities == 2)
    }

    @Test("after the suspension was signalled, sections are refused without asking until the back-off ends")
    func backOffAfterExpiration() async throws {
        let provider = ControlledActivityProvider(mode: .refuse)
        let clock = ManualClock()
        let suspensionGuard = SuspensionGuard(provider: provider, backOffInterval: .seconds(5), now: { clock.now })

        let first = try await onDedicatedThread { try suspensionGuard.run { 1 } }
        #expect(first == 1)
        #expect(await onDedicatedThread { provider.waitUntilExpired(1) })

        // The system would grant again, but the process must get the chance to be suspended.
        provider.mode = .grant
        clock.advance(by: .seconds(4))
        let refused = await onDedicatedThread { Result { try suspensionGuard.run { 2 } } }
        #expect(isSuspensionImminent(refused))
        #expect(provider.startedActivities == 1, "no activity is requested during the back-off")

        clock.advance(by: .seconds(1))
        let value = try await onDedicatedThread { try suspensionGuard.run { 3 } }
        #expect(value == 3)
        #expect(provider.startedActivities == 2)
    }

    @Test("entering the foreground ends the back-off")
    func resumeEndsBackOff() async throws {
        let provider = ControlledActivityProvider(mode: .refuse)
        let clock = ManualClock()
        let suspensionGuard = SuspensionGuard(provider: provider, now: { clock.now })

        _ = try await onDedicatedThread { try suspensionGuard.run { 0 } }
        #expect(await onDedicatedThread { provider.waitUntilExpired(1) })
        let refused = await onDedicatedThread { Result { try suspensionGuard.run { 1 } } }
        #expect(isSuspensionImminent(refused))

        provider.mode = .grant
        suspensionGuard.resume()
        let value = try await onDedicatedThread { try suspensionGuard.run { 2 } }
        #expect(value == 2)
    }

    @Test("concurrent sections share one activity, whose block waits for the last of them")
    func concurrentSectionsShareActivity() async throws {
        let provider = ControlledActivityProvider(mode: .manual)
        let suspensionGuard = SuspensionGuard(provider: provider, lingerInterval: .zero)
        let first = Checkpoint()
        let second = Checkpoint()

        // Both sections run before the grant.
        async let firstResult: Int = onDedicatedThread {
            try suspensionGuard.run {
                first.pass()
                return 1
            }
        }
        #expect(await onDedicatedThread { first.waitUntilReached() })
        async let secondResult: Int = onDedicatedThread {
            try suspensionGuard.run {
                second.pass()
                return 2
            }
        }
        #expect(await onDedicatedThread { second.waitUntilReached() })
        #expect(provider.startedActivities == 1)

        provider.grant(0)
        first.release()
        #expect(try await firstResult == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.ended == 0, "the block waits for the running section")

        second.release()
        #expect(try await secondResult == 2)
        #expect(await onDedicatedThread { provider.waitUntilEnded(1) })
        #expect(provider.startedActivities == 1)
    }
}

@Suite("Depots keep the process unsuspended during cross-process file access", .offCooperativePool)
struct DepotSuspensionGuardTests {
    private func makeDepot(
        at url: URL,
        suspensionGuard: SuspensionGuard,
        multiProcess: Bool = true,
        readOnly: Bool = false,
    ) -> Depot {
        Depot(
            configuration: .init(
                directoryURL: url,
                enableMultiProcessSupport: multiProcess,
                readOnly: readOnly,
                memoryCache: .disabled,
            ),
            overrides: .init(
                initSweepDelay: .seconds(3600),
                suspensionGuard: suspensionGuard,
            ),
        )
    }

    /// Lets the system signal the suspension: new critical sections are refused afterwards.
    private func signalSuspension(_ suspensionGuard: SuspensionGuard, _ provider: ControlledActivityProvider) async {
        // The activities of earlier operations ended, so the next section starts a new one.
        let started = provider.startedActivities
        #expect(await onDedicatedThread { provider.waitUntilEnded(started) })
        provider.mode = .refuse
        #expect(await onDedicatedThread { (try? suspensionGuard.run { true }) == true })
        #expect(await onDedicatedThread { provider.waitUntilExpired(1) })
    }

    @Test(
        "multi-process operations run inside an activity, and fail without changes after the suspension was signalled"
    )
    func multiProcessOperations() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ControlledActivityProvider(mode: .grant)
        let suspensionGuard = SuspensionGuard(provider: provider, lingerInterval: .zero)
        let depot = makeDepot(at: url, suspensionGuard: suspensionGuard)
        let key = depot.register(keyPath: "value", coder: .json(String.self))
        let other = depot.register(keyPath: "other", coder: .json(String.self))

        try await depot.set(value: "v1", for: key)
        #expect(provider.startedActivities > 0)

        await signalSuspension(suspensionGuard, provider)
        let operations: [(String, @Sendable () async throws -> Void)] = [
            ("set", { try await depot.set(value: "v2", for: key) }),
            ("remove", { try await depot.remove(valueFor: key) }),
            ("remove pattern", { try await depot.remove(valuesFor: Key.all) }),
            ("transaction", { try await depot.transaction { try $0.set(value: "v2", for: other) } }),
            ("removeExpired", { _ = try await depot.removeExpired() }),
            ("reset", { try await depot.reset() }),
            ("checkForExternalChanges", { try await depot.checkForExternalChanges() }),
        ]
        for (name, operation) in operations {
            await #expect(throws: DepotError.suspensionImminent, "\(name)") { try await operation() }
        }

        // Nothing changed, and reads do not need an activity.
        #expect(try await depot.get(valueFor: key) == "v1")
        #expect(try await depot.get(valueFor: other) == nil)

        provider.mode = .grant
        suspensionGuard.resume()
        try await depot.set(value: "v3", for: key)
        #expect(try await depot.get(valueFor: key) == "v3")
        try await depot.verifyIntegrity()
    }

    @Test("multi-process operations complete although the system never calls the activity's block")
    func operationsWithoutGrant() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ControlledActivityProvider(mode: .manual)
        let depot = makeDepot(at: url, suspensionGuard: SuspensionGuard(provider: provider))
        let key = depot.register(keyPath: "value", coder: .json(String.self))

        try await onDedicatedThread {
            try depot.addFilePresenter()
            try depot.set(value: "v1", for: key)
            try depot.transaction { try $0.set(value: "v2", for: key) }
            _ = try depot.removeExpired()
            try depot.checkForExternalChanges()
            try depot.removeFilePresenter()
        }
        try await depot.set(value: "v3", for: key)
        try await depot.transaction { try $0.set(value: "v4", for: key) }
        try await depot.checkForExternalChanges()

        #expect(try await depot.get(valueFor: key) == "v4")
        #expect(provider.startedActivities == 1)
        try await depot.verifyIntegrity()
    }

    @Test("a read-only depot checks for external changes inside an activity")
    func readOnlyCheck() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = makeDepot(
            at: url,
            suspensionGuard: SuspensionGuard(provider: ControlledActivityProvider(mode: .grant), lingerInterval: .zero)
        )
        try await writer.set(value: "v1", for: writer.register(keyPath: "value", coder: .json(String.self)))

        let provider = ControlledActivityProvider(mode: .grant)
        let suspensionGuard = SuspensionGuard(provider: provider, lingerInterval: .zero)
        let reader = makeDepot(at: url, suspensionGuard: suspensionGuard, readOnly: true)
        let key = reader.register(keyPath: "value", coder: .json(String.self))
        try await reader.checkForExternalChanges()
        #expect(provider.startedActivities > 0)

        await signalSuspension(suspensionGuard, provider)
        await #expect(throws: DepotError.suspensionImminent) { try await reader.checkForExternalChanges() }
        #expect(try await reader.get(valueFor: key) == "v1")

        provider.mode = .grant
        suspensionGuard.resume()
        try await reader.checkForExternalChanges()
    }

    @Test("single-process depots never start an activity")
    func singleProcessDepot() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ControlledActivityProvider(mode: .refuse)
        let depot = makeDepot(at: url, suspensionGuard: SuspensionGuard(provider: provider), multiProcess: false)
        let key = depot.register(keyPath: "value", coder: .json(String.self))

        try await depot.set(value: "v1", for: key)
        try await depot.transaction { try $0.set(value: "v2", for: key) }
        _ = try await depot.removeExpired()
        try await depot.checkForExternalChanges()
        try await depot.reset()
        try await depot.verifyIntegrity()
        #expect(provider.startedActivities == 0)
    }
}
