// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// Shared logic for depot implementations (key registration, coder lookup, observer management, encryption).
///
/// Depot types own a `DepotCore` via composition instead of inheriting from a common base class.
final class DepotCore: Sendable {
    // MARK: - State

    private final class RegistryState: @unchecked Sendable {
        var keys = Set<Key>() {
            didSet {
                _sortedKeys = nil
                patternKeysByFirstComponentCache = nil
            }
        }

        var coders = [Key: any RegisteredCoderProtocol]()
        var encryptionConfiguration: EncryptionConfiguration?

        private var _sortedKeys: [Key]?
        var sortedKeys: [Key] {
            if let sortedKeys = _sortedKeys {
                return sortedKeys
            }

            let sortedKeys = keys.sorted()
            _sortedKeys = sortedKeys

            return sortedKeys
        }

        private var patternKeysByFirstComponentCache: [KeyComponent: [Key]]?
        var patternKeysByFirstComponent: [KeyComponent: [Key]] {
            if let patternKeysByFirstComponentCache {
                return patternKeysByFirstComponentCache
            }

            // Only pattern keys can match other concrete keys (otherwise it's an exact match).
            // Keep them sorted by specificity (same order as `sortedKeys.reversed()` would produce).
            let patternKeysDescending =
                keys
                .filter { !$0.isDistinct }
                .sorted()
                .reversed()

            var byFirstComponent = [KeyComponent: [Key]]()
            for key in patternKeysDescending {
                let first = key.components[0]
                byFirstComponent[first, default: []].append(key)
            }

            patternKeysByFirstComponentCache = byFirstComponent
            return byFirstComponent
        }

        init(encryptionConfiguration: EncryptionConfiguration?) {
            self.encryptionConfiguration = encryptionConfiguration
        }
    }

    private final class ObserverState: @unchecked Sendable {
        var observers = [WeakObserver]()
    }

    /// Executes observer work items serially in FIFO order using a single draining Task.
    private final class SerialObserverExecutor: Sendable {
        private struct WorkItem: Sendable {
            let execute: @Sendable () async -> Void
        }

        private let continuation: AsyncStream<WorkItem>.Continuation
        private let drainTask: Task<Void, Never>

        init() {
            let (stream, continuation) = AsyncStream<WorkItem>.makeStream()
            self.continuation = continuation

            drainTask = Task {
                for await work in stream {
                    await work.execute()
                }
            }
        }

        deinit {
            continuation.finish()
            drainTask.cancel()
        }

        /// Enqueues a work item for serial execution.
        func enqueue(_ work: @escaping @Sendable () async -> Void) {
            continuation.yield(WorkItem(execute: work))
        }

        /// Waits until all previously enqueued work items have been executed.
        func waitForPending() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.continuation.yield(
                    WorkItem {
                        continuation.resume()
                    },
                )
            }
        }
    }

    /// A weak wrapper around `ValueObserverProtocol`.
    private struct WeakObserver: Sendable {
        weak var value: (any ValueObserverProtocol)?

        init(_ observer: any ValueObserverProtocol) {
            value = observer
        }
    }

    // MARK: - Properties

    private let registryState: OSAllocatedUnfairLock<RegistryState>
    private let observerState: OSAllocatedUnfairLock<ObserverState>
    private let observerExecutor: SerialObserverExecutor
    private let observerCount = OSAllocatedUnfairLock(initialState: 0)

    // MARK: - Init

    init(encryptionConfiguration: EncryptionConfiguration? = nil) {
        registryState = OSAllocatedUnfairLock(
            uncheckedState: RegistryState(encryptionConfiguration: encryptionConfiguration),
        )
        observerState = OSAllocatedUnfairLock(uncheckedState: ObserverState())
        observerExecutor = SerialObserverExecutor()
    }

    // MARK: - Key Registration

    var keys: Set<Key> {
        registryState.withLock { $0.keys }
    }

    @discardableResult
    func register<V: Sendable>(key: some KeyProtocol, coder: some Coder<V>, expiry: Duration? = nil) -> TypedKey<V> {
        precondition(expiry == nil || expiry! > .zero, "Expiry duration must be positive")

        let key =
            if let key = key as? Key {
                key
            } else {
                Key(key)
            }

        return registryState.withLock { state in
            state.keys.insert(key)
            state.coders[key] = Registration<V>(AnyCoder(coder), expiry: expiry)

            return key.typed()
        }
    }

    /// Returns the registered expiry duration for the given key, resolving via pattern matching.
    func expiry(for key: some KeyProtocol) -> Duration? {
        let key =
            if let key = key as? Key {
                key
            } else {
                Key(key)
            }

        return registryState.withLock { state in
            Self.resolveRegistration(for: key, in: state)?.registrationExpiry()
        }
    }

    /// Returns the value type name and coder description for a registered key.
    func registrationInfo(for key: Key) -> (valueType: String, coderDescription: String)? {
        registryState.withLock { state in
            guard let registration = state.coders[key] else {
                return nil
            }
            return (registration.registrationValueType(), registration.registrationDescription())
        }
    }

    // MARK: - Coder Lookup

    /// Returns a (copy of a) previously registered coder for the key, wrapped with
    /// the current depot-wide encryption configuration if one is set.
    ///
    /// - Parameters:
    ///   - key: The key to look for a coder.
    ///
    /// - Returns: A (copy of a) previously registered coder for the key.
    ///
    /// - Throws: ``DepotError/unregisteredKey`` if the key hasn't been registered before.
    /// - Throws: ``DepotError/mismatchedTypes`` if the type of the typed key doesn't match the registered key.
    ///
    /// > Pattern keys (with wildcards) are supported.
    func coder<V>(for key: some KeyProtocol, as _: V.Type = V.self) throws -> AnyCoder<V> where V: Sendable {
        let key =
            if let key = key as? Key {
                key
            } else {
                Key(key)
            }

        do {
            return try registryState.withLock { state in
                guard let registration = Self.resolveRegistration(for: key, in: state) else {
                    LOG(level: .error, message: "DepotCore: no coder registered for key '\(key.keyPath)'")
                    throw DepotError.unregisteredKey(keyPath: key.keyPath)
                }

                let baseCoder: AnyCoder<V> = try registration.coder(as: V.self)

                if let encryptionConfiguration = state.encryptionConfiguration {
                    return EncryptedCoder(baseCoder, configuration: encryptionConfiguration).eraseToAnyCoder()
                }

                return baseCoder
            }
        } catch {
            if case let .mismatchedTypes(kp, expected, actual) = error as? DepotError, kp.isEmpty {
                throw DepotError.mismatchedTypes(keyPath: key.keyPath, expected: expected, actual: actual)
            }

            throw error
        }
    }

    func coderAndExpiry<V>(for key: some KeyProtocol, as _: V.Type = V.self) throws -> (AnyCoder<V>, Duration?)
    where V: Sendable {
        let key =
            if let key = key as? Key {
                key
            } else {
                Key(key)
            }

        do {
            return try registryState.withLock { state in
                guard let registration = Self.resolveRegistration(for: key, in: state) else {
                    LOG(level: .error, message: "DepotCore: no coder registered for key '\(key.keyPath)'")
                    throw DepotError.unregisteredKey(keyPath: key.keyPath)
                }

                let baseCoder: AnyCoder<V> = try registration.coder(as: V.self)
                let expiry = registration.registrationExpiry()

                let finalCoder: AnyCoder<V>
                if let encryptionConfiguration = state.encryptionConfiguration {
                    finalCoder = EncryptedCoder(baseCoder, configuration: encryptionConfiguration).eraseToAnyCoder()
                } else {
                    finalCoder = baseCoder
                }

                return (finalCoder, expiry)
            }
        } catch {
            if case let .mismatchedTypes(kp, expected, actual) = error as? DepotError, kp.isEmpty {
                throw DepotError.mismatchedTypes(keyPath: key.keyPath, expected: expected, actual: actual)
            }

            throw error
        }
    }

    /// Resolves the registered coder entry for the given key (direct match or pattern fallback).
    private static func resolveRegistration(for key: Key, in state: RegistryState) -> (any RegisteredCoderProtocol)? {
        if let registration = state.coders[key] {
            return registration
        }

        let components = key.components
        let firstComponent = components[0]

        let candidatesForFirst = state.patternKeysByFirstComponent[firstComponent] ?? []
        let wildcardFirst = state.patternKeysByFirstComponent[.wildcard] ?? []
        let globstarFirst = state.patternKeysByFirstComponent[.globstar] ?? []

        for nextKey in candidatesForFirst where nextKey.matches(key) {
            return state.coders[nextKey]
        }

        if !firstComponent.isPattern {
            for nextKey in wildcardFirst where nextKey.matches(key) {
                return state.coders[nextKey]
            }
            for nextKey in globstarFirst where nextKey.matches(key) {
                return state.coders[nextKey]
            }
        }

        return nil
    }

    // MARK: - Encryption

    var encryptionConfiguration: EncryptionConfiguration? {
        registryState.withLock { $0.encryptionConfiguration }
    }

    // MARK: - Observer Management

    func observe<V>(
        valueFor key: some TypedDistinctKeyProtocol<V>,
        initialValue: Bool,
        update: @escaping @Sendable (Result<V?, Error>) async -> Void,
        in depot: Depot,
    ) -> any DepotCancellable where V: Sendable {
        let observer = SingleValueObserver<V>(key: key, update: update)

        // Enqueue the initial delivery BEFORE making the observer visible,
        // so it is always ahead of any write-triggered notifications.
        if initialValue {
            scheduleObserverTask { [weak depot] in
                guard let depot, !observer.isCancelled else {
                    return
                }

                await observer.initial(in: depot)
            }
        }

        addObserver(observer)

        return ClosureDepotCancellable { observer.cancel() }
    }

    func observe<V>(
        valuesFor key: some TypedKeyProtocol<V>,
        initialValues: Bool,
        update: @escaping @Sendable (Result<[V], Error>) async -> Void,
        in depot: Depot,
    ) -> any DepotCancellable where V: Sendable {
        let observer = MultiValueObserver<V>(key: key, update: update)

        // Enqueue the initial delivery BEFORE making the observer visible,
        // so it is always ahead of any write-triggered notifications.
        if initialValues {
            scheduleObserverTask { [weak depot] in
                guard let depot, !observer.isCancelled else {
                    return
                }

                await observer.initial(in: depot)
            }
        }

        addObserver(observer)

        return ClosureDepotCancellable { observer.cancel() }
    }

    func observe<V>(
        availableValuesFor key: some TypedKeyProtocol<V>,
        initialValues: Bool,
        update: @escaping @Sendable (Result<AvailableValuesResult<V>, Error>) async -> Void,
        in depot: Depot,
    ) -> any DepotCancellable where V: Sendable {
        let observer = AvailableValuesObserver<V>(key: key, update: update)

        if initialValues {
            scheduleObserverTask { [weak depot] in
                guard let depot, !observer.isCancelled else {
                    return
                }

                await observer.initial(in: depot)
            }
        }

        addObserver(observer)

        return ClosureDepotCancellable { observer.cancel() }
    }

    func waitForPendingObservations() async {
        await observerExecutor.waitForPending()
    }

    // MARK: - AsyncStream Observation

    func values<V>(
        for key: some TypedDistinctKeyProtocol<V>,
        initialValue: Bool,
        in depot: Depot,
    ) -> AsyncStream<Result<V?, Error>> where V: Sendable {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancellable = observe(
                valueFor: key,
                initialValue: initialValue,
                update: { result in
                    continuation.yield(result)
                },
                in: depot
            )

            continuation.onTermination = { @Sendable _ in
                cancellable.cancel()
            }
        }
    }

    func values<V>(
        for key: some TypedKeyProtocol<V>,
        initialValues: Bool,
        in depot: Depot,
    ) -> AsyncStream<Result<[V], Error>> where V: Sendable {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancellable = observe(
                valuesFor: key,
                initialValues: initialValues,
                update: { result in
                    continuation.yield(result)
                },
                in: depot
            )

            continuation.onTermination = { @Sendable _ in
                cancellable.cancel()
            }
        }
    }

    func availableValues<V>(
        for key: some TypedKeyProtocol<V>,
        initialValues: Bool,
        in depot: Depot,
    ) -> AsyncStream<Result<AvailableValuesResult<V>, Error>> where V: Sendable {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancellable = observe(
                availableValuesFor: key,
                initialValues: initialValues,
                update: { result in
                    continuation.yield(result)
                },
                in: depot
            )

            continuation.onTermination = { @Sendable _ in
                cancellable.cancel()
            }
        }
    }

    /// - Parameters:
    ///   - key: The key to notify observers for.
    ///   - value: The new value.
    ///   - depot: The depot that triggered the notification.
    ///
    /// > Important: Only distinct keys are allowed.
    func notifyObservers(updated key: some DistinctKeyProtocol, with value: some Sendable, in depot: Depot) {
        guard observerCount.withLock({ $0 }) > 0 else {
            return
        }

        let observers = collectMatchingObservers { $0.key.matches(key) }
        for observer in observers {
            scheduleObserverTask { [weak depot] in
                guard let depot else {
                    return
                }

                await observer.updated(value, in: depot)
            }
        }
    }

    /// Notifies observers about a removed value.
    ///
    /// - Parameters:
    ///   - key: The key to notify observers for.
    ///   - depot: The depot that triggered the notification.
    ///
    /// > Pattern keys (with wildcards) are supported.
    func notifyObservers(removed key: some KeyProtocol, in depot: Depot) {
        guard observerCount.withLock({ $0 }) > 0 else {
            return
        }

        let observers = collectMatchingObservers { $0.key.matches(key) || key.matches($0.key) }
        for observer in observers {
            scheduleObserverTask { [weak depot] in
                guard let depot else {
                    return
                }

                await observer.removed(in: depot)
            }
        }
    }

    /// Notifies observers about modified and removed keys.
    ///
    /// - Parameters:
    ///   - modified: The keys that have been modified.
    ///   - removed: The keys that have been removed.
    ///   - depot: The depot that triggered the notification.
    ///
    /// > Warning: Only distinct keys are allowed. A key should either be in modified or removed, but not both.
    func notifyObservers(
        modified: Set<some DistinctKeyProtocol>,
        removed: Set<some DistinctKeyProtocol>,
        in depot: Depot,
    ) {
        guard observerCount.withLock({ $0 }) > 0 else {
            return
        }

        let observers = collectActiveObservers()
        for observer in observers {
            // Check modified keys first and only trigger one update per observer
            var matched = false
            for key in modified {
                guard observer.key.matches(key) else {
                    continue
                }

                scheduleObserverTask { [weak depot] in
                    guard let depot else {
                        return
                    }

                    await observer.modified(in: depot)
                }

                matched = true
                break
            }

            if matched {
                continue
            }

            for key in removed {
                guard observer.key.matches(key) || key.matches(observer.key) else {
                    continue
                }

                scheduleObserverTask { [weak depot] in
                    guard let depot else {
                        return
                    }

                    await observer.removed(in: depot)
                }

                break
            }
        }
    }

    /// Notifies observers about a transaction outcome.
    ///
    /// - Note: `emptyPatternRemovals` is used to preserve the non-transaction behavior where removing a
    ///   pattern key still triggers a removal notification even if it matched no concrete keys.
    func notifyTransactionObservers(
        modified: Set<some DistinctKeyProtocol>,
        removed: Set<some DistinctKeyProtocol>,
        emptyPatternRemovals: [Key],
        didRemoveAll: Bool,
        in depot: Depot,
    ) {
        if didRemoveAll {
            // Key.all matches every observer, including those whose keys were
            // re-written after the removeAll in the same transaction. That is
            // sufficient: observers are pull-based (`removed(in:)` re-reads the
            // depot), so they deliver the freshly written value, not `nil`.
            notifyObservers(removed: Key.all, in: depot)
            return
        }

        if !modified.isEmpty || !removed.isEmpty {
            notifyObservers(modified: modified, removed: removed, in: depot)
        }

        for key in emptyPatternRemovals {
            notifyObservers(removed: key, in: depot)
        }
    }

    // MARK: - Private

    private func addObserver(_ observer: any ValueObserverProtocol) {
        let newCount = observerCount.withLock { count -> Int in
            count += 1
            return count
        }
        observerState.withLock { state in
            state.observers.removeAll { $0.value == nil || ($0.value?.isCancelled ?? true) }
            state.observers.append(WeakObserver(observer))
        }
        LOG(level: .debug, message: "Observer registered for '\(observer.key)' (total: \(newCount))")
    }

    /// Collects all active (non-cancelled, non-nil) observers, pruning dead entries.
    private func collectActiveObservers() -> [any ValueObserverProtocol] {
        let active = observerState.withLock { state in
            var active = [any ValueObserverProtocol]()
            state.observers.removeAll { weak in
                guard let observer = weak.value else {
                    return true
                }
                if observer.isCancelled {
                    return true
                }

                active.append(observer)
                return false
            }

            return active
        }

        let previousCount = observerCount.withLock { count -> Int in
            let previous = count
            count = active.count
            return previous
        }
        if active.count < previousCount {
            LOG(level: .debug, message: "Observer cancelled (remaining: \(active.count))")
        }
        return active
    }

    /// Collects matching active observers that pass the given predicate, pruning dead entries.
    private func collectMatchingObservers(
        _ predicate: @Sendable (any ValueObserverProtocol) -> Bool,
    ) -> [any ValueObserverProtocol] {
        let (matching, remainingCount) = observerState.withLock { state in
            var matching = [any ValueObserverProtocol]()
            state.observers.removeAll { weak in
                guard let observer = weak.value else {
                    return true
                }
                if observer.isCancelled {
                    return true
                }

                if predicate(observer) {
                    matching.append(observer)
                }

                return false
            }

            return (matching, state.observers.count)
        }

        let previousCount = observerCount.withLock { count -> Int in
            let previous = count
            count = remainingCount
            return previous
        }
        if remainingCount < previousCount {
            LOG(level: .debug, message: "Observer cancelled (remaining: \(remainingCount))")
        }
        return matching
    }

    /// Schedules an observer notification for serial execution, preserving FIFO order.
    private func scheduleObserverTask(_ work: @escaping @Sendable () async -> Void) {
        observerExecutor.enqueue(work)
    }
}
