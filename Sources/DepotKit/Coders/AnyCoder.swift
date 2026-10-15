// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// A coder that performs type erasure by wrapping another coder.
///
/// ``AnyCoder`` is a concrete implementation of ``Coder`` that has no significant properties of its own, and forwards every function to its wrapped coder.
///
/// Use ``AnyCoder`` to wrap a coder whose type has details you don't want to expose across API boundaries, such as different modules.
/// When you use type erasure this way, you can change the underlying coder implementation over time without affecting existing consumers of your API.
///
/// You can use ``Coder/eraseToAnyCoder()`` to wrap a coder with ``AnyCoder``.
public struct AnyCoder<Value: Sendable>: Coder {
    private let box: any _AnyCoderBox<Value>

    /// Designated initializer.
    ///
    /// Typically, you would use ``Coder/eraseToAnyCoder()`` instead.
    ///
    /// - Parameters:
    ///   - coder: The coder to wrap.
    public init<C>(_ coder: C) where Value == C.Value, C: Coder {
        if let erased = coder as? AnyCoder<Value> {
            self = erased
            return
        }

        box = _CoderBox(base: coder)
    }

    /// Fast-path initializer that keeps type erasure cheap when already erased.
    public init(_ coder: AnyCoder<Value>) {
        box = coder.box
    }

    // MARK: - Coder

    public var coderDescription: String { box.coderDescription }

    public func encode(_ value: Value) throws -> Data {
        try box.encode(value)
    }

    public func decode(_ data: Data) throws -> Value {
        try box.decode(data)
    }

}

extension Coder {
    /// Wraps this coder with a type eraser.
    ///
    /// Use ``Coder/eraseToAnyCoder()`` to expose an instance of ``AnyCoder`` to rather than this coder's actual type.
    /// This form of _type erasure_ preserves abstraction across API boundaries, such as different modules.
    /// When you expose your coder as the ``AnyCoder`` type, you can change the underlying implementation over time without affecting existing consumers of your API.
    ///
    /// - Returns: An ``AnyCoder`` wrapping this coder.
    public func eraseToAnyCoder() -> AnyCoder<Value> {
        AnyCoder(self)
    }
}

// MARK: - Private

/// Type-erasing box protocol with primary associated type for efficient existential storage.
private protocol _AnyCoderBox<Value>: Sendable {
    associatedtype Value: Sendable

    var coderDescription: String { get }
    func encode(_ value: Value) throws -> Data
    func decode(_ data: Data) throws -> Value
}

/// Box for any coder.
private struct _CoderBox<Base: Coder>: _AnyCoderBox where Base.Value: Sendable {
    typealias Value = Base.Value

    let base: Base

    var coderDescription: String { base.coderDescription }
    func encode(_ value: Value) throws -> Data { try base.encode(value) }
    func decode(_ data: Data) throws -> Value { try base.decode(data) }
}
