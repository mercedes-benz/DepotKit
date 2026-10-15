// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

// MARK: - Observation

extension Depot {
    /// Returns an `AsyncStream` that emits the current value and subsequent changes for a distinct key.
    ///
    /// The stream delivers the latest state, not a log of every change: it uses
    /// `.bufferingNewest(1)`, so a slow consumer skips intermediate values and sees only the
    /// latest one. Expiry does not emit at the deadline; see <doc:Lifecycle#Lazy-Expiry>.
    ///
    /// - Parameters:
    ///   - key: A typed distinct key identifying the value.
    ///   - initialValue: When `true` (the default), the current value is emitted immediately.
    /// - Returns: A stream of `Result<V?, Error>` values.
    public func values<V>(
        for key: some TypedDistinctKeyProtocol<V>,
        initialValue: Bool = true,
    ) -> AsyncStream<Result<V?, Error>> where V: Sendable {
        core.values(for: key, initialValue: initialValue, in: self)
    }

    /// Returns an `AsyncStream` that emits all values matching a key pattern whenever any of them change.
    ///
    /// The stream delivers the latest state, not a log of every change: it uses
    /// `.bufferingNewest(1)`, so a slow consumer skips intermediate snapshots and sees only the
    /// latest one. The order of the values in a snapshot is unspecified; sort them if you need a
    /// stable order.
    ///
    /// - Parameters:
    ///   - key: A typed key that may contain wildcards.
    ///   - initialValues: When `true` (the default), the current values are emitted immediately.
    /// - Returns: A stream of `Result<[V], Error>` snapshots.
    public func values<V>(
        for key: some TypedKeyProtocol<V>,
        initialValues: Bool = true,
    ) -> AsyncStream<Result<[V], Error>> where V: Sendable {
        core.values(for: key, initialValues: initialValues, in: self)
    }

    /// Returns an `AsyncStream` of partial-success results for a key pattern, collecting per-key errors.
    ///
    /// Like ``values(for:initialValues:)`` but wraps each emission in an ``AvailableValuesResult``
    /// so that individual decode failures don't prevent other values from being delivered.
    ///
    /// - Parameters:
    ///   - key: A typed key that may contain wildcards.
    ///   - initialValues: When `true` (the default), the current values are emitted immediately.
    /// - Returns: A stream of `Result<AvailableValuesResult<V>, Error>` snapshots.
    public func availableValues<V>(
        for key: some TypedKeyProtocol<V>,
        initialValues: Bool = true,
    ) -> AsyncStream<Result<AvailableValuesResult<V>, Error>> where V: Sendable {
        core.availableValues(for: key, initialValues: initialValues, in: self)
    }

    /// Waits until all pending observer notifications have been delivered.
    ///
    /// Useful in tests to ensure observation side-effects have settled before asserting.
    public func waitForPendingObservations() async {
        await core.waitForPendingObservations()
    }
}
