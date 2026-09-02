// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Type-erased handle to a registered coder, used by ``DepotCore`` to look up coders by key path.
protocol RegisteredCoderProtocol: AnyObject, Sendable {
    func coder<V>(as: V.Type) throws -> AnyCoder<V> where V: Sendable
    func registrationExpiry() -> Duration?
    func registrationDescription() -> String
    func registrationValueType() -> String
}
