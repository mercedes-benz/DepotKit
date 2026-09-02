// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Errors thrown by ``Depot`` operations.
///
/// Each case carries associated values that describe the context of the failure,
/// making it straightforward to present actionable diagnostics to callers.
///
/// All cases conform to `LocalizedError` with human-readable messages and hints.
public enum DepotError: Error, Equatable, Sendable {
    /// The depot is read-only and cannot be modified.
    ///
    /// Thrown by mutating operations (``Depot/set(value:for:)``, ``Depot/remove(valuesFor:)``)
    /// when the underlying depot was configured in read-only mode (e.g. ``DepotConfiguration/readOnly``).
    case readOnlyDepot

    /// The depot cannot verify its integrity because internal metadata is missing.
    ///
    /// This typically indicates a corrupted or uninitialized depot directory.
    /// Call `verifyIntegrity()` after creating a ``Depot``, or reset the depot
    /// to recreate the metadata.
    case metadataNotFound

    /// A key was used that has not been registered with a coder yet.
    ///
    /// Every key must be registered via ``Depot/register(key:coder:)-3rfq2`` (or one of its
    /// convenience overloads) before it can be used in get, set, or remove operations.
    ///
    /// - Parameter keyPath: The string representation of the unregistered key path.
    case unregisteredKey(keyPath: String)

    /// A key path is reserved for internal depot metadata and cannot be used by consumers.
    ///
    /// Choose a different key path that does not collide with the depot's internal prefix.
    ///
    /// - Parameter keyPath: The string representation of the reserved key path.
    case reservedKey(keyPath: String)

    /// The value type requested does not match the type registered for this key.
    ///
    /// This occurs when calling ``Depot/get(valueFor:)`` or ``Depot/set(value:for:)`` with
    /// a ``TypedDistinctKey`` whose `Value` type differs from the coder's type that was
    /// registered for the same key path.
    ///
    /// - Parameters:
    ///   - keyPath: The string representation of the key path where the mismatch occurred.
    ///   - expected: The type name that was requested by the caller.
    ///   - actual: The type name that was registered for this key path.
    case mismatchedTypes(keyPath: String, expected: String, actual: String)

    /// The requested operation is not available in the current context.
    ///
    /// This may occur when a platform-specific feature is called from an unsupported
    /// environment (e.g. an app extension).
    case functionNotAvailable

    /// The stored value failed its integrity check.
    ///
    /// The file exists but its CRC32 checksum does not match the payload,
    /// indicating corruption. The consumer decides whether to delete and
    /// re-create or propagate.
    ///
    /// - Parameter reason: A human-readable description of what failed.
    case integrityCheckFailed(reason: String)

    /// The file was written by a newer version of DepotKit that this reader
    /// cannot interpret.
    ///
    /// Upgrade DepotKit to the version indicated by `fileVersion` or newer.
    ///
    /// - Parameters:
    ///   - fileVersion: The format version found in the file header.
    ///   - readerVersion: The maximum version this reader supports.
    case incompatibleVersion(fileVersion: UInt8, readerVersion: UInt8)
}

extension DepotError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .readOnlyDepot:
            "The depot is read-only and cannot be modified.\nHint: Use a depot initialized without the read-only option."
        case .metadataNotFound:
            "The depot metadata could not be found.\nHint: Call verifyIntegrity() after creating the depot, or reset() to recreate it."
        case let .unregisteredKey(keyPath):
            "Key \"\(keyPath)\" is not registered.\nHint: Call depot.register(key:coder:) before get/set operations."
        case let .reservedKey(keyPath):
            "Key \"\(keyPath)\" is reserved for internal use.\nHint: Choose a different key path that does not start with the internal prefix."
        case let .mismatchedTypes(keyPath, expected, actual):
            "Type mismatch for key \"\(keyPath)\": expected \(expected) but found \(actual).\nHint: Ensure the type parameter matches the type used when registering the key\'s coder."
        case .functionNotAvailable:
            "This function is not available in the current context.\nHint: Check platform requirements and ensure this is not called from an app extension."
        case let .integrityCheckFailed(reason):
            "Integrity check failed: \(reason).\nHint: The file may be corrupted. Consider removing and re-writing the value."
        case let .incompatibleVersion(fileVersion, readerVersion):
            "File requires format version \(fileVersion) but this reader only supports up to version \(readerVersion).\nHint: Upgrade DepotKit to a newer version."
        }
    }
}
