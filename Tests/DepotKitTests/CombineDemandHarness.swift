// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if COMBINE_ENABLED && canImport(Combine)

import Combine
import DepotKit
import Foundation
import Testing
import os

@testable import DepotKitCombine

/// Lets receive handlers call back into the subscription (reentrant `request` / `cancel`).
protocol DemandControl: Sendable {
    func request(_ demand: Subscribers.Demand)
    func cancel()
}

extension DemandTestSubscriber: DemandControl {}

/// Decision applied by the error-handling variants in tests.
enum TestErrorDecision: Sendable {
    case skip
    case replaceWith(Int)
    case complete
}

struct CombineTestFailure: Error {}

/// Records the `isInitial` flags passed to error handlers.
final class IsInitialRecorder: Sendable {
    private let flags = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    private let changes = ChangeSignal()

    func record(_ isInitial: Bool) {
        flags.withLock { $0.append(isInitial) }
        changes.signal()
    }

    var recorded: [Bool] {
        flags.withLock { $0 }
    }

    /// Waits until at least `count` flags have been recorded.
    func waitForRecords(count: Int) async -> Bool {
        await changes.wait { recorded.count >= count }
    }
}

/// Receive handler working on the variant's value projected to `Int`.
typealias IntReceiveHandler = @Sendable (_ control: any DemandControl, _ value: Int?) -> Subscribers.Demand

/// A type-erased subscriber/subscription pair for one publisher variant. Delivered inputs are
/// projected to `Int?` (`-1` for a delivered `Result.failure`).
struct DemandHarness: Sendable {
    let control: any DemandControl
    let values: @Sendable () -> [Int?]
    let completionCount: @Sendable () -> Int
    /// The number of `.finished` completions among the received completions.
    let finishedCount: @Sendable () -> Int
    let overlappingCalls: @Sendable () -> Int
    /// The subscription created for the subscriber, if any.
    let probe: @Sendable () -> (any DepotObservationSubscriptionProbe)?
    let processElement: @Sendable (_ value: Int) -> Bool
    let processFailureElement: @Sendable () -> Bool

    /// Feeds a successful element carrying `value` directly into the subscription.
    ///
    /// - Returns: Whether the subscription reports that observation should stop.
    @discardableResult
    func process(_ value: Int) -> Bool {
        processElement(value)
    }

    /// Feeds a top-level failure element directly into the subscription.
    @discardableResult
    func processFailure() -> Bool {
        processFailureElement()
    }

    func waitForValues(count: Int) async -> Bool {
        await waitUntil { values().count >= count }
    }

    func waitForProcessed(count: Int) async -> Bool {
        await waitUntil { (probe()?.processedElementCount ?? 0) >= count }
    }
}

/// A depot with the keys used by the live (end-to-end) harnesses.
struct LiveCombineFixture: Sendable {
    let depot: Depot
    let valueKey: TypedDistinctKey<Int>
    let patternKey: TypedKey<Int>
    let itemKey: TypedDistinctKey<Int>

    static func make(fileBacked: Bool) -> LiveCombineFixture {
        let depot = fileBacked ? Depot.temporary() : Depot()
        _ = depot.register(key: Key.from("value"), coder: .data(Int.self))
        let patternKey = depot.register(key: Key.from("items" / .wildcard), coder: .data(Int.self))
        return LiveCombineFixture(
            depot: depot,
            valueKey: Key.from("value", as: Int.self),
            patternKey: patternKey,
            itemKey: Key.from("items" / "a", as: Int.self),
        )
    }

    /// Writes `value` to the key observed by `variant` and waits until observers were notified.
    func write(_ value: Int, for variant: CombineVariant) async throws {
        if variant.isSingleValue {
            try await depot.set(value: value, for: valueKey)
        } else {
            try await depot.set(value: value, for: itemKey)
        }
        await depot.waitForPendingObservations()
    }

    func removeDirectory() {
        if let url = depot.configuration.directoryURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Every Combine publisher variant offered by `DepotKitCombine`.
enum CombineVariant: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case single
    case singleHandlingErrors
    case multi
    case multiHandlingErrors
    case availableValues
    case availableValuesHandlingErrors

    static let errorHandling: [CombineVariant] = allCases.filter(\.handlesErrors)

    var testDescription: String { rawValue }

    var isSingleValue: Bool {
        self == .single || self == .singleHandlingErrors
    }

    var handlesErrors: Bool {
        switch self {
        case .singleHandlingErrors, .multiHandlingErrors, .availableValuesHandlingErrors:
            true
        case .single, .multi, .availableValues:
            false
        }
    }

    enum Source {
        /// The subscription is created directly with a stream that never yields, so tests drive
        /// it synchronously through ``DemandHarness/process``.
        case detached(initialValues: Bool = true)
        /// The subscription is created by the public `Depot.published(...)` API.
        case live(LiveCombineFixture, initialValues: Bool)
    }

    func makeHarness(
        _ source: Source,
        initialDemand: Subscribers.Demand,
        onError decision: TestErrorDecision = .skip,
        isInitialRecorder: IsInitialRecorder? = nil,
        onReceive: @escaping IntReceiveHandler = { _, _ in .none },
    ) -> DemandHarness {
        let detachedDepot = Depot()

        switch self {
        case .single:
            return Self.build(
                initialDemand: initialDemand,
                onReceive: onReceive,
                project: { (input: Result<Int?, Error>) in (try? input.get()) ?? (input.isFailure ? -1 : nil) },
                element: { Result<Int?, Error>.success($0) },
                failure: Result<Int?, Error>.failure(CombineTestFailure()),
                attach: { subscriber in
                    switch source {
                    case let .detached(initialValues):
                        let publisher = SingleValuePublisher(
                            depot: detachedDepot,
                            key: Key.from("value", as: Int.self),
                            initialValue: initialValues,
                        )
                        subscriber.receive(
                            subscription: publisher.makeSubscription(for: subscriber) { Self.idleStream() }
                        )
                    case let .live(fixture, initialValues):
                        fixture.depot.published(valueFor: fixture.valueKey, initialValue: initialValues)
                            .subscribe(subscriber)
                    }
                },
            )

        case .singleHandlingErrors:
            let handler: @Sendable (Error, Bool) -> ErrorHandlingDecision<Int?, Error> = { _, isInitial in
                isInitialRecorder?.record(isInitial)
                return switch decision {
                case .skip: .skip
                case let .replaceWith(value): .replaceWith(value)
                case .complete: .complete(.finished)
                }
            }
            return Self.build(
                initialDemand: initialDemand,
                onReceive: onReceive,
                project: { (input: Int?) in input },
                element: { Result<Int?, Error>.success($0) },
                failure: Result<Int?, Error>.failure(CombineTestFailure()),
                attach: { subscriber in
                    switch source {
                    case let .detached(initialValues):
                        let publisher = SingleValuePublisherHandlingErrors(
                            depot: detachedDepot,
                            key: Key.from("value", as: Int.self),
                            initialValue: initialValues,
                            errorHandler: handler,
                        )
                        subscriber.receive(
                            subscription: publisher.makeSubscription(for: subscriber) { Self.idleStream() }
                        )
                    case let .live(fixture, initialValues):
                        fixture.depot.published(
                            valueFor: fixture.valueKey,
                            initialValue: initialValues,
                            errorHandler: handler,
                        )
                        .subscribe(subscriber)
                    }
                },
            )

        case .multi:
            return Self.build(
                initialDemand: initialDemand,
                onReceive: onReceive,
                project: { (input: Result<[Int], Error>) in
                    input.isFailure ? -1 : (try? input.get())?.first
                },
                element: { Result<[Int], Error>.success([$0]) },
                failure: Result<[Int], Error>.failure(CombineTestFailure()),
                attach: { subscriber in
                    switch source {
                    case let .detached(initialValues):
                        let publisher = MultiValuePublisher(
                            depot: detachedDepot,
                            key: Key.from("items" / .wildcard, as: Int.self),
                            initialValues: initialValues,
                        )
                        subscriber.receive(
                            subscription: publisher.makeSubscription(for: subscriber) { Self.idleStream() }
                        )
                    case let .live(fixture, initialValues):
                        fixture.depot.published(valuesFor: fixture.patternKey, initialValues: initialValues)
                            .subscribe(subscriber)
                    }
                },
            )

        case .multiHandlingErrors:
            let handler: @Sendable (Error, Bool) -> ErrorHandlingDecision<[Int], Error> = { _, isInitial in
                isInitialRecorder?.record(isInitial)
                return Self.arrayDecision(decision)
            }
            return Self.build(
                initialDemand: initialDemand,
                onReceive: onReceive,
                project: { (input: [Int]) in input.first },
                element: { Result<[Int], Error>.success([$0]) },
                failure: Result<[Int], Error>.failure(CombineTestFailure()),
                attach: { subscriber in
                    switch source {
                    case let .detached(initialValues):
                        let publisher = MultiValuePublisherHandlingErrors(
                            depot: detachedDepot,
                            key: Key.from("items" / .wildcard, as: Int.self),
                            initialValues: initialValues,
                            errorHandler: handler,
                        )
                        subscriber.receive(
                            subscription: publisher.makeSubscription(for: subscriber) { Self.idleStream() }
                        )
                    case let .live(fixture, initialValues):
                        fixture.depot.published(
                            valuesFor: fixture.patternKey,
                            initialValues: initialValues,
                            errorHandler: handler,
                        )
                        .subscribe(subscriber)
                    }
                },
            )

        case .availableValues:
            return Self.build(
                initialDemand: initialDemand,
                onReceive: onReceive,
                project: { (input: Result<AvailableValuesResult<Int>, Error>) in
                    input.isFailure ? -1 : (try? input.get())?.values.first
                },
                element: { Self.available($0) },
                failure: Result<AvailableValuesResult<Int>, Error>.failure(CombineTestFailure()),
                attach: { subscriber in
                    switch source {
                    case let .detached(initialValues):
                        let publisher = AvailableValuesPublisher(
                            depot: detachedDepot,
                            key: Key.from("items" / .wildcard, as: Int.self),
                            initialValues: initialValues,
                        )
                        subscriber.receive(
                            subscription: publisher.makeSubscription(for: subscriber) { Self.idleStream() }
                        )
                    case let .live(fixture, initialValues):
                        fixture.depot.published(availableValuesFor: fixture.patternKey, initialValues: initialValues)
                            .subscribe(subscriber)
                    }
                },
            )

        case .availableValuesHandlingErrors:
            let handler: @Sendable (Error, Bool) -> ErrorHandlingDecision<[Int], Error> = { _, isInitial in
                isInitialRecorder?.record(isInitial)
                return Self.arrayDecision(decision)
            }
            return Self.build(
                initialDemand: initialDemand,
                onReceive: onReceive,
                project: { (input: [Int]) in input.first },
                element: { Self.available($0) },
                failure: Result<AvailableValuesResult<Int>, Error>.failure(CombineTestFailure()),
                attach: { subscriber in
                    switch source {
                    case let .detached(initialValues):
                        let publisher = AvailableValuesPublisherHandlingErrors(
                            depot: detachedDepot,
                            key: Key.from("items" / .wildcard, as: Int.self),
                            initialValues: initialValues,
                            errorHandler: handler,
                        )
                        subscriber.receive(
                            subscription: publisher.makeSubscription(for: subscriber) { Self.idleStream() }
                        )
                    case let .live(fixture, initialValues):
                        fixture.depot.published(
                            availableValuesFor: fixture.patternKey,
                            initialValues: initialValues,
                            errorHandler: handler,
                        )
                        .subscribe(subscriber)
                    }
                },
            )
        }
    }

    // MARK: Helpers

    /// A stream that never yields and never finishes (until its consumer is cancelled): elements
    /// are fed exclusively through `process(_:)`. A finishing stream would complete the
    /// subscription, as it does when the depot is deallocated.
    private static func idleStream<Element>() -> AsyncStream<Element> {
        AsyncStream { _ in }
    }

    private static func available(_ value: Int) -> Result<AvailableValuesResult<Int>, Error> {
        .success(AvailableValuesResult(keyedValues: [Key.from("items" / "a"): value], keyedErrors: [:]))
    }

    private static func arrayDecision(_ decision: TestErrorDecision) -> ErrorHandlingDecision<[Int], Error> {
        switch decision {
        case .skip: .skip
        case let .replaceWith(value): .replaceWith([value])
        case .complete: .complete(.finished)
        }
    }

    private static func build<Input, Failure: Error, Element: Sendable>(
        initialDemand: Subscribers.Demand,
        onReceive: @escaping IntReceiveHandler,
        project: @escaping @Sendable (Input) -> Int?,
        element: @escaping @Sendable (Int) -> Element,
        failure: Element,
        attach: (DemandTestSubscriber<Input, Failure>) -> Void,
    ) -> DemandHarness {
        let subscriber = DemandTestSubscriber<Input, Failure>(initialDemand: initialDemand) { subscriber, input in
            onReceive(subscriber, project(input))
        }
        attach(subscriber)

        typealias Concrete = DepotObservationSubscription<DemandTestSubscriber<Input, Failure>, Element>
        let subscription: @Sendable () -> Concrete? = { subscriber.subscription as? Concrete }
        return DemandHarness(
            control: subscriber,
            values: { subscriber.values.map(project) },
            completionCount: { subscriber.completions.count },
            finishedCount: {
                subscriber.completions.count { completion in
                    if case .finished = completion { true } else { false }
                }
            },
            overlappingCalls: { subscriber.overlappingCalls },
            probe: { subscription() },
            processElement: { value in
                guard let subscription = subscription() else {
                    Issue.record("Subscriber has no DepotObservationSubscription")
                    return true
                }
                return subscription.process(element(value))
            },
            processFailureElement: {
                guard let subscription = subscription() else {
                    Issue.record("Subscriber has no DepotObservationSubscription")
                    return true
                }
                return subscription.process(failure)
            },
        )
    }
}

extension Result {
    fileprivate var isFailure: Bool {
        if case .failure = self { true } else { false }
    }
}

#endif
