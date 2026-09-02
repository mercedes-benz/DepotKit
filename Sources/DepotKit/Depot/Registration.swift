// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Internal registration entry stored in `DepotCore`.
///
/// Holds the type-erased coder and optional expiry duration for a registered key.
final class Registration<Value: Sendable>: RegisteredCoderProtocol, @unchecked Sendable {
    let coder: AnyCoder<Value>
    let expiry: Duration?

    init(_ coder: AnyCoder<Value>, expiry: Duration? = nil) {
        self.coder = coder
        self.expiry = expiry
    }

    /// Returns the coder cast to the requested value type, or throws on mismatch.
    func coder<V>(as _: V.Type) throws -> AnyCoder<V> where V: Sendable {
        guard let coder = coder as? AnyCoder<V> else {
            throw DepotError.mismatchedTypes(keyPath: "", expected: "\(V.self)", actual: "\(Value.self)")
        }
        return coder
    }

    func registrationExpiry() -> Duration? {
        expiry
    }

    func registrationDescription() -> String {
        coder.coderDescription
    }

    func registrationValueType() -> String {
        String(describing: Value.self)
    }
}
