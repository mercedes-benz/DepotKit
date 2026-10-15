// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// The result of a partial-success multi-value read.
///
/// Unlike ``Depot/get(valuesFor:)-51ef6`` which throws on the first decode failure,
/// ``Depot/get(availableValuesFor:)-21xqj`` and the corresponding observation streams
/// collect per-key errors separately and return all values that decoded successfully.
///
/// ## Usage
///
/// ```swift
/// let result = try depot.get(availableValuesFor: allSettingsKey)
/// print("Loaded \(result.values.count) settings")
/// for (key, error) in result.keyedErrors {
///     print("Failed to decode \(key): \(error)")
/// }
///
/// // Access values with their keys:
/// for (key, value) in result.keyedValues {
///     print("\(key): \(value)")
/// }
/// ```
public struct AvailableValuesResult<Value: Sendable>: Sendable {
    /// The values that were successfully decoded, paired with their keys.
    public let keyedValues: [DistinctKey: Value]

    /// Per-key errors for values that failed to decode, paired with their keys.
    public let keyedErrors: [DistinctKey: any Error & Sendable]

    /// The successfully decoded values as a flat array (unkeyed convenience).
    ///
    /// The order of the values is unspecified; sort them if you need a stable order.
    public var values: [Value] {
        Array(keyedValues.values)
    }

    /// The errors as a flat array (unkeyed convenience), in unspecified order.
    public var errors: [any Error & Sendable] {
        Array(keyedErrors.values)
    }

    /// Creates an available-values result.
    public init(keyedValues: [DistinctKey: Value], keyedErrors: [DistinctKey: any Error & Sendable]) {
        self.keyedValues = keyedValues
        self.keyedErrors = keyedErrors
    }
}
