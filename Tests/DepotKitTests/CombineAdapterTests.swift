// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if COMBINE_ENABLED && canImport(Combine)

import Combine
import Foundation
import Testing
import os

@testable import DepotKit
@testable import DepotKitCombine

/// End-to-end tests of the public `DepotKitCombine` API: initial and subsequent delivery, error
/// handling, cancellation, and subscription lifetime. Demand handling is covered separately by
/// `CombineDemandTests`.
@Suite("Combine adapters: delivery, errors, and lifetime")
struct CombineAdapterTests {
    // MARK: - Helpers

    private struct TestError: Error, Equatable {}

    /// The delivered value, or `-1` for a delivered `Result.failure`.
    private static func value(of result: Result<Int?, Error>) -> Int? {
        (try? result.get()) ?? (result.isFailure ? -1 : nil)
    }

    /// Every publisher variant mapped to a common output so lifetime tests can treat them alike.
    /// The mapping operators forward completions and cancellation unchanged.
    private static func erasedPublisher(
        _ variant: CombineVariant,
        _ fixture: LiveCombineFixture,
    ) -> AnyPublisher<Int, Error> {
        let depot = fixture.depot
        return switch variant {
        case .single:
            depot.published(valueFor: fixture.valueKey).map { _ in 0 }.setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        case .singleHandlingErrors:
            depot.published(valueFor: fixture.valueKey, errorHandler: { _, _ in .skip }).map { _ in 0 }
                .eraseToAnyPublisher()
        case .multi:
            depot.published(valuesFor: fixture.patternKey).map { _ in 0 }.setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        case .multiHandlingErrors:
            depot.published(valuesFor: fixture.patternKey, errorHandler: { _, _ in .skip }).map { _ in 0 }
                .eraseToAnyPublisher()
        case .availableValues:
            depot.published(availableValuesFor: fixture.patternKey).map { _ in 0 }
                .setFailureType(to: Error.self).eraseToAnyPublisher()
        case .availableValuesHandlingErrors:
            depot.published(availableValuesFor: fixture.patternKey, errorHandler: { _, _ in .skip }).map { _ in 0 }
                .eraseToAnyPublisher()
        }
    }

    private static let variantsAndModes: [(CombineVariant, Bool)] = CombineVariant.allCases.flatMap { variant in
        [(variant, false), (variant, true)]
    }

    /// A multi-process depot without memory cache, so external modifications are re-read from disk.
    private static func makeExternallyModifiableDepot() -> (Depot, URL) {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled),
            overrides: .init(initSweepDelay: .seconds(3600)),
        )
        return (depot, url)
    }

    /// Damages the value bytes of the file so that its CRC32 no longer matches, the way a
    /// non-coordinated foreign writer or storage corruption would.
    private static func corruptFile(at url: URL) throws {
        var data = try Data(contentsOf: url)
        data[data.count - 1] ^= 0xFF
        try data.write(to: url)
    }

    // MARK: - Delivery

    @Test("single-value publishers deliver the initial value and every later change", arguments: [false, true])
    func singleValueDelivery(fileBacked: Bool) async throws {
        let fixture = LiveCombineFixture.make(fileBacked: fileBacked)
        defer { fixture.removeDirectory() }
        let depot = fixture.depot
        try await depot.set(value: 1, for: fixture.valueKey)

        let results = DeliveryLog<Int?>()
        let unwrapped = DeliveryLog<Int?>()
        let resultCancellable = depot.published(valueFor: fixture.valueKey)
            .sink { results.append(Self.value(of: $0)) }
        let unwrappedCancellable = depot.published(valueFor: fixture.valueKey, errorHandler: { _, _ in .skip })
            .sink(receiveCompletion: { _ in Issue.record("unexpected completion") }, receiveValue: unwrapped.append)

        var expected: [Int?] = [1]
        #expect(await waitUntil { results.count == 1 && unwrapped.count == 1 })

        let steps: [Int?] = [2, nil, 3]
        for step in steps {
            if let step {
                try await depot.set(value: step, for: fixture.valueKey)
            } else {
                try await depot.remove(valueFor: fixture.valueKey)
            }
            expected.append(step)
            let count = expected.count
            #expect(await waitUntil { results.count == count && unwrapped.count == count })
        }

        #expect(results.all == expected)
        #expect(unwrapped.all == expected)
        resultCancellable.cancel()
        unwrappedCancellable.cancel()
    }

    @Test("multi-value publishers deliver the initial snapshot and every later change", arguments: [false, true])
    func multiValueDelivery(fileBacked: Bool) async throws {
        let fixture = LiveCombineFixture.make(fileBacked: fileBacked)
        defer { fixture.removeDirectory() }
        let depot = fixture.depot
        let itemA = Key.from("items" / "a", as: Int.self)
        let itemB = Key.from("items" / "b", as: Int.self)
        try await depot.set(value: 1, for: itemA)

        let results = DeliveryLog<[Int]>()
        let unwrapped = DeliveryLog<[Int]>()
        let available = DeliveryLog<[Int]>()
        let availableUnwrapped = DeliveryLog<[Int]>()
        var cancellables = Set<AnyCancellable>()
        depot.published(valuesFor: fixture.patternKey)
            .sink { results.append(((try? $0.get()) ?? [-1]).sorted()) }
            .store(in: &cancellables)
        depot.published(valuesFor: fixture.patternKey, errorHandler: { _, _ in .skip })
            .sink(receiveCompletion: { _ in Issue.record("unexpected completion") }) { unwrapped.append($0.sorted()) }
            .store(in: &cancellables)
        depot.published(availableValuesFor: fixture.patternKey)
            .sink { available.append(((try? $0.get())?.values ?? [-1]).sorted()) }
            .store(in: &cancellables)
        depot.published(availableValuesFor: fixture.patternKey, errorHandler: { _, _ in .skip })
            .sink(receiveCompletion: { _ in Issue.record("unexpected completion") }) {
                availableUnwrapped.append($0.sorted())
            }
            .store(in: &cancellables)
        let logs = [results, unwrapped, available, availableUnwrapped]

        var expected: [[Int]] = [[1]]
        #expect(await waitUntil { logs.allSatisfy { $0.count == 1 } })

        let steps: [(@Sendable () async throws -> Void, [Int])] = [
            ({ try await depot.set(value: 2, for: itemB) }, [1, 2]),
            ({ try await depot.remove(valueFor: itemA) }, [2]),
            ({ try await depot.remove(valuesFor: fixture.patternKey) }, []),
        ]
        for (mutation, snapshot) in steps {
            try await mutation()
            expected.append(snapshot)
            let count = expected.count
            #expect(await waitUntil { logs.allSatisfy { $0.count == count } })
        }

        for log in logs {
            #expect(log.all == expected)
        }
        cancellables.removeAll()
    }

    // MARK: - Errors

    @Test("errors before registration: Result publishers emit the failure, default handlers recover")
    func initialErrors() async throws {
        let depot = Depot()
        let valueKey = Key.from("value", as: Int.self)
        let patternKey = Key.from("items" / .wildcard, as: Int.self)

        let results = DeliveryLog<Result<Int?, Error>>()
        let defaultSingle = DeliveryLog<Int?>()
        let defaultMulti = DeliveryLog<[Int]>()
        let defaultAvailable = DeliveryLog<[Int]>()
        var cancellables = Set<AnyCancellable>()
        depot.published(valueFor: valueKey).sink(receiveValue: results.append).store(in: &cancellables)
        depot.published(valueFor: valueKey)
            .sink(receiveCompletion: { _ in Issue.record("unexpected completion") }, receiveValue: defaultSingle.append)
            .store(in: &cancellables)
        depot.published(valuesFor: patternKey)
            .sink(receiveCompletion: { _ in Issue.record("unexpected completion") }, receiveValue: defaultMulti.append)
            .store(in: &cancellables)
        depot.published(availableValuesFor: patternKey)
            .sink(
                receiveCompletion: { _ in Issue.record("unexpected completion") },
                receiveValue: defaultAvailable.append,
            )
            .store(in: &cancellables)

        #expect(
            await waitUntil {
                results.count == 1 && defaultSingle.count == 1 && defaultMulti.count == 1 && defaultAvailable.count == 1
            }
        )
        #expect(throws: DepotError.unregisteredKey(keyPath: "value")) { try results.last?.get() }
        #expect(defaultSingle.all == [nil])
        #expect(defaultMulti.all == [[]])
        #expect(defaultAvailable.all == [[]])

        // After registration, later changes are delivered by the same subscriptions.
        depot.register(key: Key.from("value"), coder: .data(Int.self))
        depot.register(key: Key.from("items" / .wildcard), coder: .data(Int.self))
        try await depot.set(value: 5, for: valueKey)
        try await depot.set(value: 6, for: Key.from("items" / "a", as: Int.self))

        #expect(await waitUntil { results.count == 2 && defaultSingle.count == 2 })
        #expect(await waitUntil { defaultMulti.last == [6] && defaultAvailable.last == [6] })
        #expect(try results.last?.get() == 5)
        #expect(defaultSingle.all == [nil, 5])
        cancellables.removeAll()
    }

    @Test("later read failures are emitted, skipped, or replaced, and observation continues")
    func laterErrors() async throws {
        let (depot, url) = Self.makeExternallyModifiableDepot()
        defer { try? FileManager.default.removeItem(at: url) }
        let key = depot.register(keyPath: "value", coder: .data(Int.self))
        try await depot.set(value: 1, for: key)

        let resultSubscriber = DemandTestSubscriber<Result<Int?, Error>, Never>(initialDemand: .unlimited)
        let skipSubscriber = DemandTestSubscriber<Int?, Error>(initialDemand: .unlimited)
        let replaceSubscriber = DemandTestSubscriber<Int?, Error>(initialDemand: .unlimited)
        depot.published(valueFor: key).subscribe(resultSubscriber)
        depot.published(valueFor: key).subscribe(skipSubscriber)
        depot.published(valueFor: key, errorHandler: { _, _ in .replaceWith(-1) }).subscribe(replaceSubscriber)

        #expect(await resultSubscriber.waitForValues(count: 1))
        #expect(await skipSubscriber.waitForValues(count: 1))
        #expect(await replaceSubscriber.waitForValues(count: 1))

        try Self.corruptFile(at: try depot.fileURL(for: key))
        try await depot.checkForExternalChanges()

        #expect(await resultSubscriber.waitForValues(count: 2))
        #expect(await replaceSubscriber.waitForValues(count: 2))
        let skipProbe = try #require(skipSubscriber.subscription as? any DepotObservationSubscriptionProbe)
        #expect(await waitUntil { skipProbe.processedElementCount == 2 })

        let failure = try #require(resultSubscriber.values.last)
        let readError = #expect(throws: DepotError.self) { try failure.get() }
        if case .integrityCheckFailed = readError {
        } else {
            Issue.record("expected an integrity error, got \(String(describing: readError))")
        }
        #expect(skipSubscriber.values == [1])
        #expect(replaceSubscriber.values == [1, -1])

        // A later successful write is delivered to every subscription.
        try await depot.set(value: 2, for: key)
        #expect(await resultSubscriber.waitForValues(count: 3))
        #expect(await skipSubscriber.waitForValues(count: 2))
        #expect(await replaceSubscriber.waitForValues(count: 3))
        #expect(try resultSubscriber.values.last?.get() == 2)
        #expect(skipSubscriber.values == [1, 2])
        #expect(replaceSubscriber.values == [1, -1, 2])

        for completions in [
            resultSubscriber.completions.count, skipSubscriber.completions.count, replaceSubscriber.completions.count,
        ] {
            #expect(completions == 0)
        }
        resultSubscriber.cancel()
        skipSubscriber.cancel()
        replaceSubscriber.cancel()
    }

    @Test("a complete(.failure) decision fails the subscriber and releases the depot observation")
    func completeWithFailure() async throws {
        let depot = Depot()
        let key = Key.from("value", as: Int.self)
        let subscriber = DemandTestSubscriber<Int?, Error>(initialDemand: .unlimited)
        depot.published(valueFor: key, errorHandler: { _, _ in .complete(.failure(TestError())) })
            .subscribe(subscriber)

        #expect(await subscriber.waitForCompletion())
        guard case let .failure(error) = subscriber.completions.first else {
            Issue.record("expected a failure completion, got \(subscriber.completions)")
            return
        }
        #expect(error is TestError)
        #expect(await waitUntil { depot.core.activeStreamCount == 0 })

        depot.register(key: Key.from("value"), coder: .data(Int.self))
        try await depot.set(value: 1, for: key)
        await depot.waitForPendingObservations()
        #expect(subscriber.values.isEmpty)
        #expect(subscriber.completions.count == 1)
    }

    // MARK: - Cancellation and lifetime

    @Test("cancelling stops delivery and releases the depot observation", arguments: variantsAndModes)
    func cancellationReleasesObservation(variant: CombineVariant, fileBacked: Bool) async throws {
        let fixture = LiveCombineFixture.make(fileBacked: fileBacked)
        defer { fixture.removeDirectory() }
        let harness = variant.makeHarness(.live(fixture, initialValues: true), initialDemand: .unlimited)
        #expect(await harness.waitForValues(count: 1))
        #expect(fixture.depot.core.activeStreamCount == 1)

        harness.control.cancel()
        #expect(await waitUntil { fixture.depot.core.activeStreamCount == 0 })

        try await fixture.write(1, for: variant)
        #expect(harness.values().count == 1)
        #expect(harness.completionCount() == 0)
    }

    @Test("releasing the AnyCancellable cancels the subscription", arguments: CombineVariant.allCases)
    func releasingCancellableCancels(variant: CombineVariant) async throws {
        let fixture = LiveCombineFixture.make(fileBacked: false)
        let received = DeliveryLog<Int>()
        var cancellable: AnyCancellable? = Self.erasedPublisher(variant, fixture)
            .sink(receiveCompletion: { _ in }, receiveValue: received.append)
        #expect(await waitUntil { received.count == 1 })
        #expect(fixture.depot.core.activeStreamCount == 1)
        _ = cancellable

        cancellable = nil
        #expect(await waitUntil { fixture.depot.core.activeStreamCount == 0 })
        try await fixture.write(1, for: variant)
        #expect(received.count == 1)
    }

    @Test("a cancelled subscription releases itself and its subscriber")
    func cancelledSubscriptionIsReleased() async throws {
        let fixture = LiveCombineFixture.make(fileBacked: false)
        let weakSubscription: WeakReference<AnyObject>
        let weakSubscriber: WeakReference<ReleasingSubscriber<Result<Int?, Error>>>
        do {
            let subscriber = ReleasingSubscriber<Result<Int?, Error>>()
            weakSubscriber = WeakReference(subscriber)
            fixture.depot.published(valueFor: fixture.valueKey).subscribe(subscriber)
            weakSubscription = WeakReference(subscriber.subscription)
            #expect(await waitUntil { subscriber.count == 1 })
            #expect(!weakSubscription.isReleased)
            subscriber.cancel()
        }
        #expect(await waitUntil { weakSubscription.isReleased && weakSubscriber.isReleased })
        #expect(await waitUntil { fixture.depot.core.activeStreamCount == 0 })
    }

    @Test(
        "cancelling releases a subscriber that keeps its subscription, and the subscription",
        arguments: CombineVariant.allCases,
    )
    func cancelBreaksSubscriberCycle(variant: CombineVariant) async throws {
        let fixture = LiveCombineFixture.make(fileBacked: false)
        try await fixture.write(0, for: variant)

        let weakSubscription: WeakReference<AnyObject>
        let weakSubscriber: WeakReference<AnyObject>
        do {
            // The test subscriber keeps a strong reference to its subscription.
            let harness = variant.makeHarness(.live(fixture, initialValues: true), initialDemand: .max(1))
            #expect(await harness.waitForValues(count: 1))
            weakSubscription = WeakReference(harness.probe().map { $0 as AnyObject })
            weakSubscriber = WeakReference(harness.control as AnyObject)
            #expect(!weakSubscription.isReleased)
            harness.control.cancel()
        }
        #expect(await waitUntil { weakSubscription.isReleased && weakSubscriber.isReleased })
        #expect(await waitUntil { fixture.depot.core.activeStreamCount == 0 })
    }

    /// Subscribes a ``NonRetainingSubscriber`` (without initial values) to the publisher of `variant`.
    private static func subscribeWithoutRetaining(
        _ variant: CombineVariant,
        _ fixture: LiveCombineFixture,
    ) -> any NonRetainingSubscriberProbe {
        let depot = fixture.depot
        switch variant {
        case .single:
            let subscriber = NonRetainingSubscriber<Result<Int?, Error>, Never>()
            depot.published(valueFor: fixture.valueKey, initialValue: false).subscribe(subscriber)
            return subscriber
        case .singleHandlingErrors:
            let subscriber = NonRetainingSubscriber<Int?, Error>()
            depot.published(valueFor: fixture.valueKey, initialValue: false, errorHandler: { _, _ in .skip })
                .subscribe(subscriber)
            return subscriber
        case .multi:
            let subscriber = NonRetainingSubscriber<Result<[Int], Error>, Never>()
            depot.published(valuesFor: fixture.patternKey, initialValues: false).subscribe(subscriber)
            return subscriber
        case .multiHandlingErrors:
            let subscriber = NonRetainingSubscriber<[Int], Error>()
            depot.published(valuesFor: fixture.patternKey, initialValues: false, errorHandler: { _, _ in .skip })
                .subscribe(subscriber)
            return subscriber
        case .availableValues:
            let subscriber = NonRetainingSubscriber<Result<AvailableValuesResult<Int>, Error>, Never>()
            depot.published(availableValuesFor: fixture.patternKey, initialValues: false).subscribe(subscriber)
            return subscriber
        case .availableValuesHandlingErrors:
            let subscriber = NonRetainingSubscriber<[Int], Error>()
            depot.published(
                availableValuesFor: fixture.patternKey,
                initialValues: false,
                errorHandler: { _, _ in .skip },
            )
            .subscribe(subscriber)
            return subscriber
        }
    }

    @Test(
        "a subscription released without cancel() ends its depot observation",
        arguments: CombineVariant.allCases,
        [false, true],
    )
    func subscriptionReleasedWithoutCancel(variant: CombineVariant, writeAfterRelease: Bool) async throws {
        let fixture = LiveCombineFixture.make(fileBacked: false)
        try await fixture.write(0, for: variant)

        // Without initial values and without writes, no element is in flight that would make the
        // observation notice the released subscription.
        let subscriber = Self.subscribeWithoutRetaining(variant, fixture)
        #expect(await waitUntil { subscriber.isSubscriptionReleased })
        #expect(await waitUntil { fixture.depot.core.activeStreamCount == 0 })

        if writeAfterRelease {
            try await fixture.write(1, for: variant)
            #expect(fixture.depot.core.activeStreamCount == 0)
        }
        #expect(subscriber.receivedCount == 0)
    }

    @Test("publishers do not keep the depot alive; its deallocation completes them", arguments: variantsAndModes)
    func depotDeallocationCompletes(variant: CombineVariant, fileBacked: Bool) async throws {
        let subscriber = DemandTestSubscriber<Int, Error>(initialDemand: .unlimited)
        let weakDepot: WeakReference<Depot>
        var directory: URL?
        do {
            let fixture = LiveCombineFixture.make(fileBacked: fileBacked)
            weakDepot = WeakReference(fixture.depot)
            directory = fixture.depot.configuration.directoryURL
            Self.erasedPublisher(variant, fixture).subscribe(subscriber)
            #expect(await subscriber.waitForValues(count: 1))
        }
        defer {
            if let directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        #expect(await waitUntil { weakDepot.isReleased }, "the subscription retained the depot")
        #expect(await subscriber.waitForCompletion(), "no completion after the depot was released")
        #expect(subscriber.completions.count == 1)
        if case .failure = subscriber.completions.first {
            Issue.record("expected .finished, got \(subscriber.completions)")
        }
        #expect(subscriber.values.count == 1)
    }

    @Test("subscribing after the depot was released completes immediately", arguments: CombineVariant.allCases)
    func subscribingAfterDeallocationCompletes(variant: CombineVariant) async throws {
        var fixture: LiveCombineFixture? = LiveCombineFixture.make(fileBacked: false)
        let weakDepot = WeakReference(fixture?.depot)
        let publisher = Self.erasedPublisher(variant, try #require(fixture))
        fixture = nil
        #expect(await waitUntil { weakDepot.isReleased })

        let subscriber = DemandTestSubscriber<Int, Error>(initialDemand: .unlimited)
        publisher.subscribe(subscriber)
        #expect(subscriber.values.isEmpty)
        #expect(subscriber.completions.count == 1)
        if case .failure = subscriber.completions.first {
            Issue.record("expected .finished, got \(subscriber.completions)")
        }
    }
}

/// A subscriber that requests unlimited demand and drops its subscription when cancelled,
/// like `Subscribers.Sink`, so tests can observe the subscription's lifetime.
final class ReleasingSubscriber<Input>: Subscriber, Cancellable, @unchecked Sendable {
    typealias Failure = Never

    private struct State {
        var subscription: (any Subscription)?
        var count = 0
    }

    let combineIdentifier = CombineIdentifier()
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    var subscription: AnyObject? {
        state.withLockUnchecked { $0.subscription as AnyObject? }
    }

    var count: Int {
        state.withLockUnchecked { $0.count }
    }

    func receive(subscription: any Subscription) {
        state.withLockUnchecked { $0.subscription = subscription }
        subscription.request(.unlimited)
    }

    func receive(_: Input) -> Subscribers.Demand {
        state.withLockUnchecked { $0.count += 1 }
        return .none
    }

    func receive(completion _: Subscribers.Completion<Never>) {
        state.withLockUnchecked { $0.subscription = nil }
    }

    func cancel() {
        let subscription = state.withLockUnchecked { state in
            defer { state.subscription = nil }
            return state.subscription
        }
        subscription?.cancel()
    }
}

/// What a test can observe of a ``NonRetainingSubscriber`` regardless of its input type.
protocol NonRetainingSubscriberProbe: Sendable {
    var isSubscriptionReleased: Bool { get }
    var receivedCount: Int { get }
}

/// A subscriber that requests unlimited demand but keeps only a weak reference to its
/// subscription, so the subscription is released without ever being cancelled.
final class NonRetainingSubscriber<Input, Failure: Error>: Subscriber, NonRetainingSubscriberProbe,
    @unchecked Sendable
{
    private struct State {
        var subscription: WeakReference<AnyObject>?
        var receivedCount = 0
    }

    let combineIdentifier = CombineIdentifier()
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    var isSubscriptionReleased: Bool {
        state.withLockUnchecked { $0.subscription?.isReleased ?? false }
    }

    var receivedCount: Int {
        state.withLockUnchecked { $0.receivedCount }
    }

    func receive(subscription: any Subscription) {
        state.withLockUnchecked { $0.subscription = WeakReference(subscription as AnyObject) }
        subscription.request(.unlimited)
    }

    func receive(_: Input) -> Subscribers.Demand {
        state.withLockUnchecked { $0.receivedCount += 1 }
        return .none
    }

    func receive(completion _: Subscribers.Completion<Failure>) {}
}

extension Result {
    fileprivate var isFailure: Bool {
        if case .failure = self { true } else { false }
    }
}

#endif
