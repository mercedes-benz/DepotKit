// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if COMBINE_ENABLED && canImport(Combine)

import Combine
import Dispatch
import Foundation
import Testing
import os

@testable import DepotKit
@testable import DepotKitCombine

/// Every Combine publisher variant must honor subscriber demand.
///
/// The "detached" tests drive the shared subscription synchronously (deterministic); the
/// "live" tests go through the public `Depot.published(...)` API against memory-only and
/// file-backed depots.
@Suite("Combine demand handling")
struct CombineDemandTests {
    // MARK: - Detached (deterministic)

    @Test(
        "Initial zero demand delivers nothing until requested, then the latest value",
        arguments: CombineVariant.allCases
    )
    func initialZeroDemand(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .none)

        #expect(harness.process(1) == false)
        #expect(harness.process(2) == false)
        #expect(harness.values().isEmpty)

        harness.control.request(.max(1))
        #expect(harness.values() == [2])

        harness.process(3)
        #expect(harness.values() == [2])

        harness.control.request(.max(1))
        #expect(harness.values() == [2, 3])
        #expect(harness.overlappingCalls() == 0)
    }

    @Test("`.max(1)` with `.none` returned from receive delivers exactly one value", arguments: CombineVariant.allCases)
    func maxOneDeliversExactlyOne(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .max(1))

        for value in 1...5 {
            harness.process(value)
        }

        #expect(harness.values() == [1])
    }

    @Test(
        "Finite demand caps deliveries; later demand gets the conflated latest value",
        arguments: CombineVariant.allCases
    )
    func finiteDemand(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .max(3))

        for value in 1...5 {
            harness.process(value)
        }
        #expect(harness.values() == [1, 2, 3])

        // 4 was superseded by 5 while demand was zero.
        harness.control.request(.max(2))
        #expect(harness.values() == [1, 2, 3, 5])

        // One unit of demand is still outstanding.
        harness.process(6)
        harness.process(7)
        #expect(harness.values() == [1, 2, 3, 5, 6])
    }

    @Test("Unlimited demand delivers every value", arguments: CombineVariant.allCases)
    func unlimitedDemand(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .unlimited)

        for value in 1...100 {
            harness.process(value)
        }

        #expect(harness.values() == (1...100).map { Optional($0) })
    }

    @Test("Additional request(_:) calls accumulate demand", arguments: CombineVariant.allCases)
    func additionalRequestsAccumulate(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .max(1))

        harness.process(1)
        #expect(harness.values() == [1])

        harness.control.request(.max(1))
        harness.control.request(.max(1))
        for value in 2...4 {
            harness.process(value)
        }
        #expect(harness.values() == [1, 2, 3])

        harness.control.request(.unlimited)
        #expect(harness.values() == [1, 2, 3, 4])
        harness.process(5)
        harness.process(6)
        #expect(harness.values() == [1, 2, 3, 4, 5, 6])
    }

    @Test("Demand returned from receive(_:) is added to the outstanding demand", arguments: CombineVariant.allCases)
    func demandReturnedFromReceive(variant: CombineVariant) {
        // Asks for one more value after each of the first two deliveries.
        let harness = variant.makeHarness(.detached(), initialDemand: .max(1)) { _, value in
            (value ?? 0) < 3 ? .max(1) : .none
        }

        for value in 1...6 {
            harness.process(value)
        }

        #expect(harness.values() == [1, 2, 3])
    }

    @Test("Demand returned from receive(_:) delivers a pending value", arguments: CombineVariant.allCases)
    func returnedDemandDeliversPendingValue(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .none) { _, _ in .max(1) }

        harness.process(1)
        harness.process(2)
        harness.control.request(.max(1))
        #expect(harness.values() == [2])

        harness.process(3)
        #expect(harness.values() == [2, 3])
    }

    @Test(
        "Reentrant request(_:) from receive(_:) is honored without overlapping calls",
        arguments: CombineVariant.allCases
    )
    func reentrantRequest(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .none) { control, value in
            if value == 1 {
                control.request(.max(1))
            }
            return .none
        }

        harness.process(1)
        harness.control.request(.max(1))
        #expect(harness.values() == [1])

        harness.process(2)
        harness.process(3)
        #expect(harness.values() == [1, 2])
        #expect(harness.overlappingCalls() == 0)
    }

    @Test("Reentrant cancel() from receive(_:) stops delivery", arguments: CombineVariant.allCases)
    func reentrantCancel(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .unlimited) { control, value in
            if value == 2 {
                control.cancel()
            }
            return .unlimited
        }

        #expect(harness.process(1) == false)
        harness.process(2)
        #expect(harness.process(3) == true)
        harness.control.request(.max(5))

        #expect(harness.values() == [1, 2])
        #expect(harness.completionCount() == 0)
    }

    @Test("cancel() stops delivery and discards pending values", arguments: CombineVariant.allCases)
    func cancellationStopsDelivery(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .max(1))

        harness.process(1)
        harness.process(2)  // pending
        harness.control.cancel()
        #expect(harness.process(3) == true)
        harness.control.request(.unlimited)

        #expect(harness.values() == [1])
        #expect(harness.completionCount() == 0)
    }

    @Test("Concurrent producers and requests never exceed demand or overlap", arguments: CombineVariant.allCases)
    func concurrentProducersAndRequests(variant: CombineVariant) async {
        let harness = variant.makeHarness(.detached(), initialDemand: .none)
        let requests = 50

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for value in 1...2_000 {
                    harness.process(value)
                }
            }
            group.addTask {
                // `concurrentPerform` blocks its caller; keep it off the cooperative pool.
                await onDedicatedThread {
                    DispatchQueue.concurrentPerform(iterations: requests) { _ in
                        harness.control.request(.max(1))
                    }
                }
            }
        }
        // Remaining demand (if any) is satisfied by one final value.
        harness.process(10_000)

        let values = harness.values()
        #expect(values.count <= requests)
        #expect(values.last == 10_000 || values.count == requests)
        #expect(harness.overlappingCalls() == 0)
    }

    // MARK: - Error-handling variants

    @Test(
        "Error decisions respect demand: replacement values are conflated like ordinary values",
        arguments: CombineVariant.errorHandling,
    )
    func replacementRespectsDemand(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .max(1), onError: .replaceWith(-7))

        harness.processFailure()
        harness.processFailure()
        harness.process(1)
        #expect(harness.values() == [-7])

        harness.control.request(.max(1))
        #expect(harness.values() == [-7, 1])
    }

    @Test(
        "A completion decision completes without demand and discards the pending value",
        arguments: CombineVariant.errorHandling,
    )
    func completionWithoutDemand(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .max(1), onError: .complete)

        harness.process(1)
        harness.process(2)  // pending, no demand
        #expect(harness.processFailure() == true)

        #expect(harness.values() == [1])
        #expect(harness.completionCount() == 1)

        #expect(harness.process(3) == true)
        harness.control.request(.unlimited)
        #expect(harness.values() == [1])
        #expect(harness.completionCount() == 1)
    }

    @Test("Skipped errors consume no demand", arguments: CombineVariant.errorHandling)
    func skippedErrorsConsumeNoDemand(variant: CombineVariant) {
        let harness = variant.makeHarness(.detached(), initialDemand: .max(1), onError: .skip)

        harness.processFailure()
        harness.processFailure()
        harness.process(1)

        #expect(harness.values() == [1])
        #expect(harness.completionCount() == 0)
    }

    @Test(
        "A completion produced during receive(_:) is delivered after it returns; cancel() suppresses it",
        arguments: CombineVariant.errorHandling,
        [false, true],
    )
    func completionWaitsForInFlightReceive(variant: CombineVariant, cancelWhileWaiting: Bool) async {
        let pause = PausePoint()
        let harness = variant.makeHarness(.detached(), initialDemand: .unlimited, onError: .complete) { _, value in
            if value == 2 {
                pause.pause()
            }
            return .none
        }
        harness.process(1)

        let producer = Task { await onDedicatedThread { harness.process(2) } }
        #expect(await waitUntil { pause.isReached })
        // The completion is queued while the subscriber is still inside receive(_:).
        #expect(harness.processFailure() == true)
        #expect(harness.completionCount() == 0)
        if cancelWhileWaiting {
            harness.control.cancel()
        }

        pause.resume()
        _ = await producer.value
        // The delivering thread hands over the queued completion before process(_:) returns.
        #expect(harness.completionCount() == (cancelWhileWaiting ? 0 : 1))
        #expect(harness.values() == [1, 2])
        #expect(harness.overlappingCalls() == 0)
    }

    // MARK: - Live (public API)

    private static let liveArguments: [(CombineVariant, Bool)] = CombineVariant.allCases.flatMap { variant in
        [(variant, false), (variant, true)]
    }

    @Test("Live: `.max(1)` delivers exactly one value, later demand gets the latest", arguments: liveArguments)
    func liveMaxOne(variant: CombineVariant, fileBacked: Bool) async throws {
        let fixture = LiveCombineFixture.make(fileBacked: fileBacked)
        defer { fixture.removeDirectory() }
        try await fixture.write(0, for: variant)

        let harness = variant.makeHarness(.live(fixture, initialValues: true), initialDemand: .max(1))
        #expect(await harness.waitForValues(count: 1))
        #expect(await harness.waitForProcessed(count: 1))

        for value in 1...3 {
            try await fixture.write(value, for: variant)
            #expect(await harness.waitForProcessed(count: value + 1))
        }
        #expect(harness.values() == [0])

        harness.control.request(.max(1))
        #expect(await harness.waitForValues(count: 2))
        #expect(harness.values() == [0, 3])

        try await fixture.write(4, for: variant)
        #expect(await harness.waitForProcessed(count: 5))
        #expect(harness.values() == [0, 3])

        harness.control.cancel()
        try await fixture.write(5, for: variant)
        harness.control.request(.unlimited)
        #expect(harness.values() == [0, 3])
        #expect(harness.completionCount() == 0)
    }

    @Test("Live: initial zero demand defers observation until requested", arguments: liveArguments)
    func liveInitialZeroDemand(variant: CombineVariant, fileBacked: Bool) async throws {
        let fixture = LiveCombineFixture.make(fileBacked: fileBacked)
        defer { fixture.removeDirectory() }

        let harness = variant.makeHarness(.live(fixture, initialValues: true), initialDemand: .none)
        try await fixture.write(1, for: variant)
        try await fixture.write(2, for: variant)

        #expect(harness.values().isEmpty)
        #expect(harness.probe()?.processedElementCount == 0)

        harness.control.request(.max(1))
        #expect(await harness.waitForValues(count: 1))
        #expect(harness.values() == [2])
        harness.control.cancel()
    }

    @Test("Live: unlimited demand delivers every change", arguments: liveArguments)
    func liveUnlimitedDemand(variant: CombineVariant, fileBacked: Bool) async throws {
        let fixture = LiveCombineFixture.make(fileBacked: fileBacked)
        defer { fixture.removeDirectory() }

        let harness = variant.makeHarness(.live(fixture, initialValues: false), initialDemand: .unlimited)
        for value in 1...5 {
            try await fixture.write(value, for: variant)
            #expect(await harness.waitForProcessed(count: value))
        }

        let values = harness.values()
        #expect(values == [1, 2, 3, 4, 5])
        harness.control.cancel()
    }

    @Test(
        "Live: a removal that arrives without demand is kept as a pending nil and delivered on demand",
        arguments: liveArguments.filter { variant, _ in variant.isSingleValue },
    )
    func livePendingNil(variant: CombineVariant, fileBacked: Bool) async throws {
        let fixture = LiveCombineFixture.make(fileBacked: fileBacked)
        defer { fixture.removeDirectory() }
        try await fixture.write(1, for: variant)

        let harness = variant.makeHarness(.live(fixture, initialValues: true), initialDemand: .max(1))
        #expect(await harness.waitForValues(count: 1))
        #expect(await harness.waitForProcessed(count: 1))

        try await fixture.depot.remove(valueFor: fixture.valueKey)
        #expect(await harness.waitForProcessed(count: 2))
        #expect(harness.values() == [1])

        harness.control.request(.max(1))
        #expect(harness.values() == [1, nil])
        #expect(harness.completionCount() == 0)
        harness.control.cancel()
    }

    @Test("Live: cancel() while the observation stream is being created ends the observation")
    func liveCancelDuringStreamCreation() async throws {
        typealias Subscriber = DemandTestSubscriber<Result<Int?, Error>, Never>
        let depot = Depot()
        let key = depot.register(keyPath: "value", coder: .data(Int.self))
        try await depot.set(value: 1, for: key)
        let pause = PausePoint()

        let weakSubscription: WeakReference<AnyObject>
        let weakSubscriber: WeakReference<Subscriber>
        do {
            let subscriber = Subscriber(initialDemand: .none)
            let subscription = DepotObservationSubscription<Subscriber, Result<Int?, Error>>(
                subscriber,
                makeStream: { [weak depot] in
                    pause.pause()
                    return depot?.values(for: key, initialValue: true)
                },
                transform: { result, _ in .emit(result) },
            )
            subscriber.receive(subscription: subscription)
            weakSubscription = WeakReference(subscription)
            weakSubscriber = WeakReference(subscriber)

            let startup = Task { await onDedicatedThread { subscription.request(.unlimited) } }
            #expect(await waitUntil { pause.isReached })
            subscription.cancel()
            pause.resume()
            await startup.value

            #expect(await waitUntil { depot.core.activeStreamCount == 0 })
            try await depot.set(value: 2, for: key)
            await depot.waitForPendingObservations()
            #expect(subscriber.values.isEmpty)
            #expect(subscriber.completions.isEmpty)
        }
        #expect(await waitUntil { weakSubscription.isReleased && weakSubscriber.isReleased })
        #expect(depot.core.activeStreamCount == 0)
    }

    @Test(
        "Live: a depot released before the first demand finishes the subscription on request",
        arguments: CombineVariant.allCases,
    )
    func liveDepotReleasedBeforeFirstDemand(variant: CombineVariant) async throws {
        var fixture: LiveCombineFixture? = LiveCombineFixture.make(fileBacked: false)
        let weakDepot = WeakReference(fixture?.depot)
        let harness = variant.makeHarness(.live(try #require(fixture), initialValues: true), initialDemand: .none)
        fixture = nil
        #expect(await waitUntil { weakDepot.isReleased })

        harness.control.request(.unlimited)
        #expect(harness.completionCount() == 1)
        #expect(harness.finishedCount() == 1)
        #expect(harness.values().isEmpty)
    }

    @Test("Live: works with Combine operators (sink)")
    func liveSink() async throws {
        let fixture = LiveCombineFixture.make(fileBacked: false)
        let received = OSAllocatedUnfairLock<[Int?]>(initialState: [])

        let cancellable = fixture.depot.published(valueFor: fixture.valueKey, errorHandler: { _, _ in .skip })
            .sink(receiveCompletion: { _ in }, receiveValue: { value in received.withLock { $0.append(value) } })
        #expect(await waitUntil { received.withLock { $0.count } == 1 })

        try await fixture.write(1, for: .single)
        #expect(await waitUntil { received.withLock { $0.count } == 2 })
        #expect(received.withLock { $0 } == [nil, 1])
        cancellable.cancel()
    }
}

/// Blocks the first thread that calls `pause()` until `resume()` is called.
private final class PausePoint: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (isArmed: true, isReached: false))
    private let released = DispatchSemaphore(value: 0)

    /// Whether a thread has reached (and is blocked in) `pause()`.
    var isReached: Bool {
        state.withLock { $0.isReached }
    }

    /// Blocks the calling thread the first time it is called; later calls return immediately.
    func pause() {
        let shouldPause = state.withLock { state in
            defer { state.isArmed = false }
            if state.isArmed {
                state.isReached = true
            }
            return state.isArmed
        }
        if shouldPause {
            _ = released.wait(timeout: .now() + .seconds(30))
        }
    }

    func resume() {
        released.signal()
    }
}

#endif
