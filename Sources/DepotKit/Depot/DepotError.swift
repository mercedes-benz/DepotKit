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
    /// Thrown by mutating operations (``Depot/set(value:for:)-6afwr``, ``Depot/remove(valuesFor:)-2ei12``)
    /// when the underlying depot was configured in read-only mode (e.g. ``DepotConfiguration/readOnly``).
    case readOnlyDepot

    /// The depot cannot verify its integrity because internal metadata is missing.
    ///
    /// The metadata is created when a writable depot is opened on a directory
    /// without values, and by `reset()`. If creating it fails there (for example
    /// while protected data is unavailable), later writes and `verifyIntegrity()`
    /// of the same depot instance retry. It is missing, for example, when a
    /// read-only depot is opened before a writer created the store, while
    /// creating it keeps failing, or when it was deleted while values remained. Stored values may
    /// still be readable; do not treat this error alone as data loss.
    case metadataNotFound

    /// A key was used that has not been registered with a coder yet.
    ///
    /// Every key must be registered via ``Depot/register(key:coder:expiry:)-(KeyProtocol,AnyCoder<V>,_)`` (or one of its
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
    /// This occurs when calling ``Depot/get(valueFor:)-5hm8k`` or ``Depot/set(value:for:)-6afwr`` with
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
    /// The file is empty, its header is malformed or recognizably damaged, or the CRC32
    /// checksum in the header does not match the stored value bytes — typically
    /// accidental damage, such as a truncated file. The CRC32 is not a cryptographic check and does not detect
    /// deliberate modification. The consumer decides whether to delete and
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

    /// A key component is too long to be stored as a file name.
    ///
    /// File-backed depots store every key component as one encoded path
    /// component, which is limited to 255 bytes including the `.bin`
    /// extension of the last component. The limit is measured on the
    /// canonical (NFC) UTF-8 form of the identifier and depends on the
    /// depot's file-name format and on whether the component is the last one
    /// (see <doc:KeysAndCoders#Key-Identifiers-on-Disk>). Components are never
    /// truncated or hashed. Memory-only depots do not impose this limit.
    ///
    /// - Parameters:
    ///   - keyPath: The string representation of the key path.
    ///   - byteCount: The UTF-8 byte count of the offending component.
    ///   - maximumByteCount: The largest supported byte count for that position.
    case keyComponentTooLong(keyPath: String, byteCount: Int, maximumByteCount: Int)

    /// The system is about to suspend the process, so the depot did not start an operation
    /// that coordinates file access with other processes.
    ///
    /// Only depots with ``DepotConfiguration/enableMultiProcessSupport`` throw it, on iOS,
    /// iPadOS, tvOS, visionOS, and watchOS. A process that is suspended while it coordinates
    /// file access blocks the other processes and can be terminated by the system, so DepotKit
    /// keeps the process running during its short cross-process operations — writes, removals,
    /// transaction commits, expiry cleanup, ``Depot/reset()-z8t6``, and
    /// ``Depot/checkForExternalChanges()-6akyi`` — and refuses to start new ones once the system
    /// announces the suspension. Nothing was changed; retry when the app is active again.
    /// Finish writes before the app moves to the background, or request background time for them.
    case suspensionImminent
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
        case let .keyComponentTooLong(keyPath, byteCount, maximumByteCount):
            "A component of key \"\(keyPath)\" is \(byteCount) bytes long, but at most \(maximumByteCount) bytes fit into a file name.\nHint: Use shorter key components, e.g. split long identifiers into several components."
        case .suspensionImminent:
            "The system is about to suspend the process, so the depot did not start accessing files shared with other processes.\nHint: Finish writes before the app moves to the background, and retry when it is active again."
        }
    }
}
