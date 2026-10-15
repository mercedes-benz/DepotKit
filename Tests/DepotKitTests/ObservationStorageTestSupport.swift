// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if OBSERVATION_ENABLED && canImport(SwiftUI) && canImport(Observation)

import DepotKit

@testable import DepotKitObservation

// The adapters' storages are inert when created; the property wrappers start them from
// `update()`. These helpers create a storage that observes right away, for tests that exercise
// the storage without hosting a SwiftUI view.

extension DepotValueStorage {
    convenience init(depot: Depot, key: TypedDistinctKey<Value>, initialValue: Bool) {
        self.init()
        observe(key: key, in: depot, initialValue: initialValue)
    }
}

extension DepotValuesStorage {
    convenience init(depot: Depot, key: TypedKey<Value>, initialValues: Bool) {
        self.init()
        observe(key: key, in: depot, initialValues: initialValues)
    }
}

#endif
