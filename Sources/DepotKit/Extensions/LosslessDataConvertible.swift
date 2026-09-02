// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Types conforming to this protocol can be converted to and from `Data` losslessly.
public protocol LosslessDataConvertible: Sendable {
    /// The data representation of the receiver.
    ///
    /// - Returns: The data that represents this value.
    var dataRepresentation: Data? { get }

    /// Constructs a value from its data representation.
    ///
    /// - Parameters:
    ///   - dataRepresentation: The data that represents this value.
    init?(dataRepresentation: Data)
}
