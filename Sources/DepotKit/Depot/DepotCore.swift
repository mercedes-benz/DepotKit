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
        var count = 0
    }

    /// Executes observer work items serially in FIFO order using a single draining Task.
    private final class SerialObserverExecutor: Sendable {
        private struct WorkItem: Sendable {
            let execute: @Sendable () async -> Void
        }

        private let continuation: AsyncStream<WorkItem>.Continuation
        private let drainTask: Task<Void, Never>

        init(runsOnIOExecutor: Bool) {
            let (stream, continuation) = AsyncStream<WorkItem>.makeStream()
            self.continuation = continuation

            let drain: @Sendable @concurrent () async -> Void = {
                for await work in stream {
                    await work.execute()
                }
            }
            // Deliveries re-read values that often drive UI, so they do not inherit the priority of
            // the context that created the depot (for example, a background refresh).
            drainTask =
                runsOnIOExecutor ? startIOTask(priority: .medium, drain) : Task(priority: .medium, operation: drain)
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

    /// Type-erased handle to an active AsyncStream continuation, so we can
    /// finish all outstanding streams when the depot core is torn down.
    ///
    /// Each handle is its own identity: `AsyncStream.Continuation` is a struct,
    /// so it has no stable object identity to key on.
    final class AnyStreamHandle: Hashable, Sendable {
        private let _finish: @Sendable () -> Void

        init<T>(_ continuation: AsyncStream<T>.Continuation) {
            _finish = { continuation.finish() }
        }

        func finish() { _finish() }

        static func == (lhs: AnyStreamHandle, rhs: AnyStreamHandle) -> Bool {
            lhs === rhs
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }
    }

    // MARK: - Properties

    private let registryState: OSAllocatedUnfairLock<RegistryState>
    private let observerState: OSAllocatedUnfairLock<ObserverState>
    private let observerExecutor: SerialObserverExecutor
    private let activeStreams: OSAllocatedUnfairLock<Set<AnyStreamHandle>>
    private let afterCommitHook = OSAllocatedUnfairLock<CallbackBox?>(initialState: nil)
    private let observerAddedHook = OSAllocatedUnfairLock<CallbackBox?>(initialState: nil)

    // MARK: - Init

    /// - Parameter runsObserversOnIOExecutor: Whether observer deliveries, which re-read values from
    ///   disk, run on ``DepotIOExecutor`` (file-backed depots).
    init(encryptionConfiguration: EncryptionConfiguration? = nil, runsObserversOnIOExecutor: Bool = false) {
        registryState = OSAllocatedUnfairLock(
            uncheckedState: RegistryState(encryptionConfiguration: encryptionConfiguration),
        )
        observerState = OSAllocatedUnfairLock(uncheckedState: ObserverState())
        observerExecutor = SerialObserverExecutor(runsOnIOExecutor: runsObserversOnIOExecutor)
        activeStreams = OSAllocatedUnfairLock(uncheckedState: [])
    }

    deinit {
        let handles = activeStreams.withLock { $0 }
        for handle in handles {
            handle.finish()
        }
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

    /// Throws ``DepotError/unregisteredKey`` when the key has no registration (direct or pattern).
    func verifyRegistered(for key: some KeyProtocol) throws {
        let key =
            if let key = key as? Key {
                key
            } else {
                Key(key)
            }

        let found = registryState.withLock { state in
            Self.resolveRegistration(for: key, in: state) != nil
        }
        if !found {
            throw DepotError.unregisteredKey(keyPath: key.keyPath)
        }
    }

    /// Validates that the key is registered (directly or via a pattern) for values of type `V`
    /// and returns the registered expiry duration.
    ///
    /// No coder is built or invoked, so memory-only writes can validate without encoding.
    ///
    /// - Throws: ``DepotError/unregisteredKey`` if the key has no registration.
    /// - Throws: ``DepotError/mismatchedTypes`` if the registered value type is not `V`.
    @discardableResult
    func validateRegistration<V: Sendable>(for key: some KeyProtocol, as _: V.Type = V.self) throws -> Duration? {
        let key =
            if let key = key as? Key {
                key
            } else {
                Key(key)
            }

        let registration = registryState.withLock { state in
            Self.resolveRegistration(for: key, in: state)
        }
        guard let registration else {
            throw DepotError.unregisteredKey(keyPath: key.keyPath)
        }

        do {
            _ = try registration.coder(as: V.self)
        } catch let DepotError.mismatchedTypes(_, expected, actual) {
            throw DepotError.mismatchedTypes(keyPath: key.keyPath, expected: expected, actual: actual)
        }

        return registration.registrationExpiry()
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
        addObserver(observer, deliveringInitialValue: initialValue, in: depot)

        return ClosureDepotCancellable { observer.cancel() }
    }

    func observe<V>(
        valuesFor key: some TypedKeyProtocol<V>,
        initialValues: Bool,
        update: @escaping @Sendable (Result<[V], Error>) async -> Void,
        in depot: Depot,
    ) -> any DepotCancellable where V: Sendable {
        let observer = MultiValueObserver<V>(key: key, update: update)
        addObserver(observer, deliveringInitialValue: initialValues, in: depot)

        return ClosureDepotCancellable { observer.cancel() }
    }

    func observe<V>(
        availableValuesFor key: some TypedKeyProtocol<V>,
        initialValues: Bool,
        update: @escaping @Sendable (Result<AvailableValuesResult<V>, Error>) async -> Void,
        in depot: Depot,
    ) -> any DepotCancellable where V: Sendable {
        let observer = AvailableValuesObserver<V>(key: key, update: update)
        addObserver(observer, deliveringInitialValue: initialValues, in: depot)

        return ClosureDepotCancellable { observer.cancel() }
    }

    func waitForPendingObservations() async {
        await observerExecutor.waitForPending()
    }

    /// The number of AsyncStreams that are still registered for teardown.
    var activeStreamCount: Int {
        activeStreams.withLock { $0.count }
    }

    // MARK: - Test Hooks

    /// Installs a test-only hook that runs after a mutation has released the
    /// depot's write lock, before the mutating call returns.
    func setAfterCommitHook(_ hook: (@Sendable () -> Void)?) {
        afterCommitHook.withLock { $0 = CallbackBox(hook) }
    }

    /// Runs the hook installed with ``setAfterCommitHook(_:)``, if any.
    func runAfterCommitHook() {
        afterCommitHook.withLock { $0 }?.call()
    }

    /// Installs a test-only hook that runs at the end of every `observe` call, after the observer
    /// has been registered and its initial delivery scheduled.
    func setObserverAddedHook(_ hook: (@Sendable () -> Void)?) {
        observerAddedHook.withLock { $0 = CallbackBox(hook) }
    }

    // MARK: - AsyncStream Observation

    func values<V>(
        for key: some TypedDistinctKeyProtocol<V>,
        initialValue: Bool,
        in depot: Depot,
    ) -> AsyncStream<Result<V?, Error>> where V: Sendable {
        let streams = activeStreams
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let handle = AnyStreamHandle(continuation)
            streams.withLock { _ = $0.insert(handle) }

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
                streams.withLock { _ = $0.remove(handle) }
            }
        }
    }

    func values<V>(
        for key: some TypedKeyProtocol<V>,
        initialValues: Bool,
        in depot: Depot,
    ) -> AsyncStream<Result<[V], Error>> where V: Sendable {
        let streams = activeStreams
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let handle = AnyStreamHandle(continuation)
            streams.withLock { _ = $0.insert(handle) }

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
                streams.withLock { _ = $0.remove(handle) }
            }
        }
    }

    func availableValues<V>(
        for key: some TypedKeyProtocol<V>,
        initialValues: Bool,
        in depot: Depot,
    ) -> AsyncStream<Result<AvailableValuesResult<V>, Error>> where V: Sendable {
        let streams = activeStreams
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let handle = AnyStreamHandle(continuation)
            streams.withLock { _ = $0.insert(handle) }

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
                streams.withLock { _ = $0.remove(handle) }
            }
        }
    }

    // MARK: - Change Notification
    //
    // Each notification enqueues exactly one work item on the serial observer
    // executor for the observers registered at that moment (captured weakly).
    // Matching and observer callbacks run only when that item executes, never
    // on the caller's thread. Mutations therefore enqueue notifications while
    // still holding the depot's write lock (after applying the change), so the
    // queue reflects commit order and a pushed value can never be delivered
    // after a newer commit's notification. Removal and modification
    // notifications are pull-based (observers re-read the depot on delivery),
    // so callers outside the write lock still converge on the committed state.

    /// The per-observer action resolved when a notification is delivered.
    private enum ObserverEvent {
        case updated(any Sendable)
        case modified
        case removed
    }

    /// Notifies observers about a value written for a distinct key, pushing the new value.
    ///
    /// Call while holding the depot's write lock, after the write has been applied.
    ///
    /// - Parameters:
    ///   - key: The key to notify observers for.
    ///   - value: The new value.
    ///   - depot: The depot that triggered the notification.
    ///
    /// > Important: Only distinct keys are allowed.
    func notifyObservers(updated key: some DistinctKeyProtocol, with value: some Sendable, in depot: Depot) {
        enqueueNotification(in: depot) { observer in
            observer.key.matches(key) ? .updated(value) : nil
        }
    }

    /// Notifies observers about removed values matching `key`.
    ///
    /// Every observer whose key can match a value that `key` matches is
    /// notified — including observers of patterns that merely intersect
    /// `key` (e.g. `users/*/name` for a removal of `users/alice/*`).
    /// Prefer the `Set<DistinctKey>` overload when the concrete removed keys
    /// are known, so that only observers of actually removed values are notified.
    ///
    /// - Parameters:
    ///   - key: The key to notify observers for.
    ///   - depot: The depot that triggered the notification.
    ///
    /// > Pattern keys (with wildcards) are supported.
    func notifyObservers(removed key: some KeyProtocol, in depot: Depot) {
        let key = Key(key)
        enqueueNotification(in: depot) { observer in
            Self.keysIntersect(observer.key, key) ? .removed : nil
        }
    }

    /// Notifies observers about a set of concrete removed keys.
    ///
    /// - Parameters:
    ///   - keys: The distinct keys that have been removed.
    ///   - depot: The depot that triggered the notification.
    func notifyObservers(removed keys: Set<DistinctKey>, in depot: Depot) {
        guard !keys.isEmpty else {
            return
        }

        notifyObservers(modified: Set<DistinctKey>(), removed: keys, in: depot)
    }

    /// Notifies observers about modified and removed keys.
    ///
    /// Each observer receives at most one notification; a matching modified key takes precedence.
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
        enqueueNotification(in: depot) { observer in
            if modified.contains(where: { observer.key.matches($0) }) {
                return .modified
            }

            if removed.contains(where: { observer.key.matches($0) || $0.matches(observer.key) }) {
                return .removed
            }

            return nil
        }
    }

    /// Notifies observers about a transaction outcome.
    func notifyTransactionObservers(
        modified: Set<some DistinctKeyProtocol>,
        removed: Set<some DistinctKeyProtocol>,
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
    }

    // MARK: - Key Intersection

    /// Whether some distinct key matches both `lhs` and `rhs`.
    ///
    /// Unlike `matches(_:)`, which checks whether one key covers the other,
    /// this recognizes crossing patterns such as `users/*/name` and
    /// `users/alice/*`, which share `users/alice/name`.
    static func keysIntersect(_ lhs: some KeyProtocol, _ rhs: some KeyProtocol) -> Bool {
        // In this form every globstar matches zero or more components.
        let lhs = lhs.zeroOrMoreGlobstarComponents
        let rhs = rhs.zeroOrMoreGlobstarComponents

        // memo[i][j]: whether lhs[i...] and rhs[j...] can match a common sequence.
        var memo = [[Bool?]](repeating: [Bool?](repeating: nil, count: rhs.count + 1), count: lhs.count + 1)

        func intersect(_ i: Int, _ j: Int) -> Bool {
            if let known = memo[i][j] {
                return known
            }

            let result: Bool
            if i == lhs.count, j == rhs.count {
                result = true
            } else if i < lhs.count, lhs[i] == .globstar {
                // The globstar matches nothing, or absorbs one more component of the other side.
                result = intersect(i + 1, j) || (j < rhs.count && intersect(i, j + 1))
            } else if j < rhs.count, rhs[j] == .globstar {
                result = intersect(i, j + 1) || (i < lhs.count && intersect(i + 1, j))
            } else if i < lhs.count, j < rhs.count {
                let compatible =
                    switch (lhs[i], rhs[j]) {
                    case (.wildcard, _), (_, .wildcard):
                        true
                    case let (.segment(lhsID), .segment(rhsID)):
                        lhsID == rhsID
                    default:
                        false
                    }
                result = compatible && intersect(i + 1, j + 1)
            } else {
                result = false
            }

            memo[i][j] = result
            return result
        }

        return intersect(0, 0)
    }

    // MARK: - Private

    /// Makes `observer` visible to notifications and, if requested, schedules its initial delivery.
    ///
    /// Both happen in one critical section of `observerState`, the lock under which notifications
    /// capture their observers. A notification that captures the observer is therefore enqueued
    /// after the initial delivery, and one that misses it was committed before the initial
    /// delivery was scheduled, so that delivery reads the committed state. Scheduled separately,
    /// the initial delivery could read the value (and its callback write a new one) before the
    /// observer became visible, and the observer would miss that write.
    private func addObserver(
        _ observer: any ValueObserverProtocol,
        deliveringInitialValue initialValue: Bool,
        in depot: Depot,
    ) {
        let newCount = observerState.withLock { state -> Int in
            if initialValue {
                scheduleObserverTask { [weak depot] in
                    guard let depot, !observer.isCancelled else {
                        return
                    }

                    await observer.initial(in: depot)
                }
            }

            state.observers.removeAll { $0.value == nil || ($0.value?.isCancelled ?? true) }
            state.observers.append(WeakObserver(observer))
            state.count = state.observers.count
            return state.count
        }
        LOG(level: .debug, message: "Observer registered for '\(observer.key)' (total: \(newCount))")
        observerAddedHook.withLock { $0 }?.call()
    }

    /// Enqueues a single notification work item for the observers registered at
    /// call time. When it executes, each still-active observer is offered to
    /// `event`, and the returned event (if any) is delivered.
    ///
    /// Only weak references are captured here, so no observer can be
    /// deinitialized (and no user code run) on the caller's thread.
    private func enqueueNotification(
        in depot: Depot,
        _ event: @escaping @Sendable (any ValueObserverProtocol) -> ObserverEvent?,
    ) {
        let observers = observerState.withLock { state in
            state.count > 0 ? state.observers : []
        }
        guard !observers.isEmpty else {
            return
        }

        let observerState = observerState
        scheduleObserverTask { [weak depot] in
            guard let depot else {
                return
            }

            Self.pruneObservers(in: observerState)

            for weakObserver in observers {
                guard let observer = weakObserver.value, !observer.isCancelled else {
                    continue
                }

                switch event(observer) {
                case let .updated(value):
                    await observer.updated(value, in: depot)
                case .modified:
                    await observer.modified(in: depot)
                case .removed:
                    await observer.removed(in: depot)
                case nil:
                    continue
                }
            }
        }
    }

    /// Removes deallocated and cancelled observers.
    private static func pruneObservers(in observerState: OSAllocatedUnfairLock<ObserverState>) {
        let (remainingCount, previousCount) = observerState.withLock { state in
            state.observers.removeAll { $0.value?.isCancelled ?? true }

            let previous = state.count
            state.count = state.observers.count
            return (state.count, previous)
        }

        if remainingCount < previousCount {
            LOG(level: .debug, message: "Observer cancelled (remaining: \(remainingCount))")
        }
    }

    /// Schedules an observer notification for serial execution, preserving FIFO order.
    private func scheduleObserverTask(_ work: @escaping @Sendable () async -> Void) {
        observerExecutor.enqueue(work)
    }
}
