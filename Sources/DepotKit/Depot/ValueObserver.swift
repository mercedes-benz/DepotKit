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

/// Observes a single distinct key and delivers `Result<Value?, Error>`.
final class SingleValueObserver<Value: Sendable>: ValueObserverProtocol {
    var key: any KeyProtocol { typedDistinctKey }
    private let typedDistinctKey: TypedDistinctKey<Value>
    private let update: OSAllocatedUnfairLock<(@Sendable (Result<Value?, Error>) async -> Void)?>

    init(
        key: some DistinctKeyProtocol,
        update: @escaping @Sendable (Result<Value?, Error>) async -> Void,
    ) {
        typedDistinctKey = TypedDistinctKey(key)
        self.update = OSAllocatedUnfairLock(uncheckedState: update)
    }

    var isCancelled: Bool {
        update.withLock { $0 == nil }
    }

    func initial(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = Result {
            try depot.get(valueFor: typedDistinctKey)
        }

        await update(result)
    }

    func updated(_ value: Any, in _: Depot) async {
        guard let value = value as? Value, let update = update.withLock({ $0 }) else {
            return
        }

        await update(.success(value))
    }

    func modified(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = Result {
            try depot.get(valueFor: typedDistinctKey)
        }

        await update(result)
    }

    func removed(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = Result {
            try depot.get(valueFor: typedDistinctKey)
        }

        await update(result)
    }

    func cancel() {
        update.withLock { $0 = nil }
    }
}

/// Observes a key (distinct or pattern) and delivers `Result<[Value], Error>`.
final class MultiValueObserver<Value: Sendable>: ValueObserverProtocol {
    var key: any KeyProtocol { typedKey }
    private let typedKey: TypedKey<Value>
    private let update: OSAllocatedUnfairLock<(@Sendable (Result<[Value], Error>) async -> Void)?>

    init(key: some KeyProtocol, update: @escaping @Sendable (Result<[Value], Error>) async -> Void) {
        typedKey = TypedKey(key)
        self.update = OSAllocatedUnfairLock(uncheckedState: update)
    }

    var isCancelled: Bool {
        update.withLock { $0 == nil }
    }

    func initial(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = Result {
            try depot.get(valuesFor: typedKey)
        }

        await update(result)
    }

    func updated(_ value: Any, in depot: Depot) async {
        guard let value = value as? Value, let update = update.withLock({ $0 }) else {
            return
        }

        if key.isDistinct {
            await update(.success([value]))
            return
        }

        let result = Result {
            try depot.get(valuesFor: typedKey)
        }

        await update(result)
    }

    func modified(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = Result {
            if let distinctKey = try? typedKey.distinct() {
                if let value = try depot.get(valueFor: distinctKey) {
                    return [value]
                } else {
                    return []
                }
            }

            return try depot.get(valuesFor: typedKey)
        }

        await update(result)
    }

    func removed(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = Result {
            if let distinctKey = try? typedKey.distinct() {
                if let value = try depot.get(valueFor: distinctKey) {
                    return [value]
                } else {
                    return [Value]()
                }
            }

            return try depot.get(valuesFor: typedKey)
        }

        await update(result)
    }

    func cancel() {
        update.withLock { $0 = nil }
    }
}

/// Observes a pattern key and delivers `Result<AvailableValuesResult<Value>, Error>` with per-key results.
final class AvailableValuesObserver<Value: Sendable>: ValueObserverProtocol {
    var key: any KeyProtocol { typedKey }
    private let typedKey: TypedKey<Value>
    private let update: OSAllocatedUnfairLock<(@Sendable (Result<AvailableValuesResult<Value>, Error>) async -> Void)?>

    init(
        key: some KeyProtocol,
        update: @escaping @Sendable (Result<AvailableValuesResult<Value>, Error>) async -> Void,
    ) {
        typedKey = TypedKey(key)
        self.update = OSAllocatedUnfairLock(uncheckedState: update)
    }

    var isCancelled: Bool {
        update.withLock { $0 == nil }
    }

    func initial(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = Result {
            try depot.get(availableValuesFor: typedKey)
        }

        await update(result)
    }

    func updated(_ value: Any, in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        if let value = value as? Value, key.isDistinct, let distinctKey = try? key.distinct() {
            await update(.success(AvailableValuesResult(keyedValues: [distinctKey: value], keyedErrors: [:])))
            return
        }

        let result = Result {
            try depot.get(availableValuesFor: typedKey)
        }

        await update(result)
    }

    func modified(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = Result {
            try depot.get(availableValuesFor: typedKey)
        }

        await update(result)
    }

    func removed(in depot: Depot) async {
        guard let update = update.withLock({ $0 }) else {
            return
        }

        let result = Result {
            try depot.get(availableValuesFor: typedKey)
        }

        await update(result)
    }

    func cancel() {
        update.withLock { $0 = nil }
    }
}
