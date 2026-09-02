// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// A transaction view of a depot, providing read and write access to depot
/// storage within an isolated, atomic transaction scope.
///
/// A `DepotTransaction` is passed as `inout` to the closure of
/// ``Depot/transaction(_:)`` and **must not escape** that closure.
/// It executes while the depot's lock is held, guaranteeing that no other
/// thread can read or write the depot concurrently.
///
/// Transactions support the same read and write operations as ``Depot`` but do
/// **not** support registering keys — register keys on the depot itself before
/// starting a transaction.
///
/// ### Commit and rollback
///
/// Mutations made inside a transaction are buffered in memory and only
/// applied to storage when the closure returns successfully (**commit**).
/// If the closure throws, the buffer is discarded and the depot is left
/// exactly as it was before the transaction started (**rollback**) — no
/// files are written, no caches are touched, and no observers are notified.
///
/// Reads inside a transaction see the transaction's own uncommitted
/// mutations: a value written earlier in the same closure is returned by
/// ``get(valueFor:)``, and a removed value reads as `nil`.
///
/// ### Available operations
///
/// | Operation | Method |
/// |-----------|--------|
/// | Read a single value | ``get(valueFor:)`` |
/// | Read multiple values (wildcard key) | ``get(valuesFor:)`` |
/// | Write / overwrite a value | ``set(value:for:)`` |
/// | Check existence | ``has(valuesFor:)`` |
/// | Remove values | ``remove(valuesFor:)`` |
///
/// Convenience methods for distinct-key variants (`has(valueFor:)`,
/// `remove(valueFor:)`) and `removeAll()` are provided in an extension.
///
/// - Important: Committing is not atomic across *multiple* keys at the I/O
///   level: if an I/O error occurs while the buffer is being flushed (for
///   example, the disk is full), the error is thrown and the depot may
///   contain only part of the transaction's mutations — the same exposure
///   as a process crash between two writes. Observers are still notified
///   for the mutations that did reach storage. Each individual value is
///   written atomically and can never be corrupted.
public struct DepotTransaction: ~Copyable {
    let box: any DepotTransactionBox

    /// Returns the value for the key, or `nil` if no value exists.
    ///
    /// - Parameter key: A typed distinct key identifying the value.
    /// - Returns: The decoded value, or `nil` if the key has no stored value.
    public func get<V>(valueFor key: some TypedDistinctKeyProtocol<V>) throws -> V? where V: Sendable {
        try box.get(valueFor: key)
    }

    /// Returns all values matching the key, or an empty array if none exist.
    ///
    /// This method is fail-fast: if any matching key fails to decode, the
    /// error propagates immediately without returning partial results.
    ///
    /// - Parameter key: A typed key that may contain wildcards.
    /// - Returns: An array of decoded values.
    public func get<V>(valuesFor key: some TypedKeyProtocol<V>) throws -> [V] where V: Sendable {
        try box.get(valuesFor: key)
    }

    /// Returns all decodable values matching a key, collecting per-key errors separately.
    ///
    /// Unlike ``get(valuesFor:)`` which throws on the first decode failure,
    /// this method attempts all matching keys and partitions results into
    /// successfully decoded values and per-key errors.
    ///
    /// - Parameter key: A typed key that may contain wildcards.
    /// - Returns: An ``AvailableValuesResult`` with decoded values and per-key errors.
    public func get<V>(availableValuesFor key: some TypedKeyProtocol<V>) throws -> AvailableValuesResult<V>
    where V: Sendable {
        try box.get(availableValuesFor: key)
    }

    /// Sets the value for a key, overwriting any existing value.
    ///
    /// Pass `nil` to remove the value (equivalent to calling ``remove(valuesFor:)``
    /// with the same key).
    ///
    /// - Parameters:
    ///   - value: The value to store, or `nil` to remove.
    ///   - key: A typed distinct key identifying where to store the value.
    public mutating func set<V>(value: V?, for key: some TypedDistinctKeyProtocol<V>) throws where V: Sendable {
        try box.set(value: value, for: key)
    }

    /// Returns `true` if at least one value exists for the key.
    ///
    /// - Parameter key: A key that may contain wildcards.
    public func has(valuesFor key: some KeyProtocol) throws -> Bool {
        try box.has(valuesFor: key)
    }

    /// Returns the number of values matching the key without decoding them.
    ///
    /// - Parameter key: A key that may contain wildcards.
    /// - Returns: The count of non-expired values matching the key.
    public func count(for key: some KeyProtocol) throws -> Int {
        try box.count(for: key)
    }

    /// Removes the value(s) matching the key.
    ///
    /// If `key` contains a wildcard, all matching values are removed.
    ///
    /// - Parameter key: A key that may contain wildcards.
    public mutating func remove(valuesFor key: some KeyProtocol) throws {
        try box.remove(valuesFor: key)
    }
}

extension DepotTransaction {
    /// Returns the stored value or a default when no value exists.
    public func get<V>(
        valueFor key: some TypedDistinctKeyProtocol<V>,
        default defaultValue: @autoclosure () -> V,
    ) throws -> V where V: Sendable {
        try get(valueFor: key) ?? defaultValue()
    }

    /// Returns `true` if the value for the distinct key exists.
    public func has(valueFor key: some DistinctKeyProtocol) throws -> Bool {
        try has(valuesFor: key)
    }

    /// Removes the value for a distinct key.
    public mutating func remove(valueFor key: some DistinctKeyProtocol) throws {
        try remove(valuesFor: key)
    }

    /// Removes all values in the depot.
    public mutating func removeAll() throws {
        try remove(valuesFor: Key.all)
    }
}

// MARK: - Internal Transaction Box

/// Internal protocol for the type-erased transaction box inside ``DepotTransaction``.
protocol DepotTransactionBox: AnyObject {
    func get<V>(valueFor key: some TypedDistinctKeyProtocol<V>) throws -> V? where V: Sendable
    func get<V>(valuesFor key: some TypedKeyProtocol<V>) throws -> [V] where V: Sendable
    func get<V>(availableValuesFor key: some TypedKeyProtocol<V>) throws -> AvailableValuesResult<V> where V: Sendable
    func set<V>(value: V?, for key: some TypedDistinctKeyProtocol<V>) throws where V: Sendable
    func has(valuesFor key: some KeyProtocol) throws -> Bool
    func count(for key: some KeyProtocol) throws -> Int
    func remove(valuesFor key: some KeyProtocol) throws
}

/// Internal protocol for concrete transaction implementations.
protocol DepotTransactionOps {
    func get<V>(valueFor key: some TypedDistinctKeyProtocol<V>) throws -> V? where V: Sendable
    func get<V>(valuesFor key: some TypedKeyProtocol<V>) throws -> [V] where V: Sendable
    func get<V>(availableValuesFor key: some TypedKeyProtocol<V>) throws -> AvailableValuesResult<V> where V: Sendable
    mutating func set<V>(value: V?, for key: some TypedDistinctKeyProtocol<V>) throws where V: Sendable
    func has(valuesFor key: some KeyProtocol) throws -> Bool
    func count(for key: some KeyProtocol) throws -> Int
    mutating func remove(valuesFor key: some KeyProtocol) throws
}

/// Concrete box that forwards ``DepotTransaction`` calls through an `UnsafeMutablePointer`
/// to a concrete transaction implementation. The pointer is only valid within the
/// `transaction` closure scope.
final class DepotTransactionPointerBox<T: DepotTransactionOps>: DepotTransactionBox, @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<T>

    init(_ pointer: UnsafeMutablePointer<T>) {
        self.pointer = pointer
    }

    func get<V>(valueFor key: some TypedDistinctKeyProtocol<V>) throws -> V? where V: Sendable {
        try pointer.pointee.get(valueFor: key)
    }

    func get<V>(valuesFor key: some TypedKeyProtocol<V>) throws -> [V] where V: Sendable {
        try pointer.pointee.get(valuesFor: key)
    }

    func get<V>(availableValuesFor key: some TypedKeyProtocol<V>) throws -> AvailableValuesResult<V> where V: Sendable {
        try pointer.pointee.get(availableValuesFor: key)
    }

    func set<V>(value: V?, for key: some TypedDistinctKeyProtocol<V>) throws where V: Sendable {
        try pointer.pointee.set(value: value, for: key)
    }

    func has(valuesFor key: some KeyProtocol) throws -> Bool {
        try pointer.pointee.has(valuesFor: key)
    }

    func count(for key: some KeyProtocol) throws -> Int {
        try pointer.pointee.count(for: key)
    }

    func remove(valuesFor key: some KeyProtocol) throws {
        try pointer.pointee.remove(valuesFor: key)
    }
}

// MARK: - ModifyAction

/// Describes what a ``Depot/modify(valueFor:action:)`` closure wants to do
/// with the current value.
///
/// Using an explicit enum avoids the ambiguity of a `(V?) -> V?` closure where
/// returning `nil` could mean either "I don't want to change anything" or
/// "I want to remove the stored value."
///
/// ```swift
/// try depot.modify(valueFor: counterKey) { current in
///     guard let count = current else { return .update(1) }
///     return count >= 100 ? .remove : .update(count + 1)
/// }
/// ```
public enum ModifyAction<Value: Sendable>: Sendable {
    /// Keep the current value unchanged. No write is performed.
    case keep

    /// Update the stored value.
    case update(Value)

    /// Remove the value from the depot.
    case remove
}
