// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// Observer that receives depot value changes and delivers them as typed results.
///
/// - `updated(_:in:)` delivers the pushed value directly, avoiding a re-read.
/// - `modified(in:)` and `removed(in:)` re-read from the depot to get the current state.
protocol ValueObserverProtocol: AnyObject, DepotCancellable, Sendable {
    var key: any KeyProtocol { get }
    var isCancelled: Bool { get }

    func initial(in depot: Depot) async
    func updated(_ value: Any, in depot: Depot) async
    func modified(in depot: Depot) async
    func removed(in depot: Depot) async
}

/// An immutable reference to an observer's update callback.
///
/// The observers keep this box, not the function itself, in their lock (see ``CallbackBox``).
private final class UpdateCallback<Output: Sendable>: Sendable {
    let call: @Sendable (Result<Output, Error>) async -> Void

    init(_ call: @escaping @Sendable (Result<Output, Error>) async -> Void) {
        self.call = call
    }
}

/// Observes a single distinct key and delivers `Result<Value?, Error>`.
final class SingleValueObserver<Value: Sendable>: ValueObserverProtocol {
    var key: any KeyProtocol { typedDistinctKey }
    private let typedDistinctKey: TypedDistinctKey<Value>
    private let update: OSAllocatedUnfairLock<UpdateCallback<Value?>?>

    init(
        key: some DistinctKeyProtocol,
        update: @escaping @Sendable (Result<Value?, Error>) async -> Void,
    ) {
        typedDistinctKey = TypedDistinctKey(key)
        self.update = OSAllocatedUnfairLock(initialState: UpdateCallback(update))
    }

    var isCancelled: Bool {
        update.withLock { $0 == nil }
    }

    func initial(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = await depot.observedRead {
            try depot.get(valueFor: typedDistinctKey)
        }

        await update.call(result)
    }

    func updated(_ value: Any, in _: Depot) async {
        guard let value = value as? Value, let update = update.withLock({ $0 }) else {
            return
        }

        await update.call(.success(value))
    }

    func modified(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = await depot.observedRead {
            try depot.get(valueFor: typedDistinctKey)
        }

        await update.call(result)
    }

    func removed(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = await depot.observedRead {
            try depot.get(valueFor: typedDistinctKey)
        }

        await update.call(result)
    }

    func cancel() {
        update.withLock { $0 = nil }
    }
}

/// Observes a key (distinct or pattern) and delivers `Result<[Value], Error>`.
final class MultiValueObserver<Value: Sendable>: ValueObserverProtocol {
    var key: any KeyProtocol { typedKey }
    private let typedKey: TypedKey<Value>
    private let update: OSAllocatedUnfairLock<UpdateCallback<[Value]>?>

    init(key: some KeyProtocol, update: @escaping @Sendable (Result<[Value], Error>) async -> Void) {
        typedKey = TypedKey(key)
        self.update = OSAllocatedUnfairLock(initialState: UpdateCallback(update))
    }

    var isCancelled: Bool {
        update.withLock { $0 == nil }
    }

    func initial(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = await depot.observedRead {
            try depot.get(valuesFor: typedKey)
        }

        await update.call(result)
    }

    func updated(_ value: Any, in depot: Depot) async {
        guard let value = value as? Value, let update = update.withLock({ $0 }) else {
            return
        }

        if key.isDistinct {
            await update.call(.success([value]))
            return
        }

        let result = await depot.observedRead {
            try depot.get(valuesFor: typedKey)
        }

        await update.call(result)
    }

    func modified(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = await depot.observedRead {
            if let distinctKey = try? typedKey.distinct() {
                if let value = try depot.get(valueFor: distinctKey) {
                    return [value]
                } else {
                    return []
                }
            }

            return try depot.get(valuesFor: typedKey)
        }

        await update.call(result)
    }

    func removed(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = await depot.observedRead {
            if let distinctKey = try? typedKey.distinct() {
                if let value = try depot.get(valueFor: distinctKey) {
                    return [value]
                } else {
                    return [Value]()
                }
            }

            return try depot.get(valuesFor: typedKey)
        }

        await update.call(result)
    }

    func cancel() {
        update.withLock { $0 = nil }
    }
}

/// Observes a pattern key and delivers `Result<AvailableValuesResult<Value>, Error>` with per-key results.
final class AvailableValuesObserver<Value: Sendable>: ValueObserverProtocol {
    var key: any KeyProtocol { typedKey }
    private let typedKey: TypedKey<Value>
    private let update: OSAllocatedUnfairLock<UpdateCallback<AvailableValuesResult<Value>>?>

    init(
        key: some KeyProtocol,
        update: @escaping @Sendable (Result<AvailableValuesResult<Value>, Error>) async -> Void,
    ) {
        typedKey = TypedKey(key)
        self.update = OSAllocatedUnfairLock(initialState: UpdateCallback(update))
    }

    var isCancelled: Bool {
        update.withLock { $0 == nil }
    }

    func initial(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = await depot.observedRead {
            try depot.get(availableValuesFor: typedKey)
        }

        await update.call(result)
    }

    func updated(_ value: Any, in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        if let value = value as? Value, key.isDistinct, let distinctKey = try? key.distinct() {
            await update.call(.success(AvailableValuesResult(keyedValues: [distinctKey: value], keyedErrors: [:])))
            return
        }

        let result = await depot.observedRead {
            try depot.get(availableValuesFor: typedKey)
        }

        await update.call(result)
    }

    func modified(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = await depot.observedRead {
            try depot.get(availableValuesFor: typedKey)
        }

        await update.call(result)
    }

    func removed(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = await depot.observedRead {
            try depot.get(availableValuesFor: typedKey)
        }

        await update.call(result)
    }

    func cancel() {
        update.withLock { $0 = nil }
    }
}

extension Depot {
    /// Runs a read for an observer delivery via ``performBlocking(_:)``, so that it does not block
    /// Swift concurrency's cooperative pool where the system allows it.
    @concurrent
    fileprivate func observedRead<T: Sendable>(_ read: @Sendable () throws -> T) async -> Result<T, any Error> {
        await performBlocking { Result { try read() } }
    }
}
