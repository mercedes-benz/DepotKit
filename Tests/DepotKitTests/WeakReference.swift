// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

/// A weak reference that can be polled from `@Sendable` closures (e.g. `waitUntil`) to verify
/// that an object was released. The reference is set once and only read afterwards.
final class WeakReference<Object: AnyObject>: @unchecked Sendable {
    weak let object: Object?

    init(_ object: Object?) {
        self.object = object
    }

    var isReleased: Bool {
        object == nil
    }
}
