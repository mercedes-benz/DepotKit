// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Combine
import DepotKit
import DepotKitCombine
import Foundation
import Observation

/// Drives the "last refresh" status line with Combine.
///
/// `depot.published(valueFor:)` bridges depot observation into a Combine
/// pipeline — handy when existing reactive code (debounce, combineLatest, …)
/// should react to depot changes.
@MainActor
@Observable
final class RefreshStatusModel {
    private(set) var lastRefresh: Date?

    @ObservationIgnored
    private var cancellables = Set<AnyCancellable>()

    init(store: DepotStore) {
        store.depot
            .published(valueFor: store.lastRefreshKey)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                if case let .success(date) = result {
                    self?.lastRefresh = date
                }
            }
            .store(in: &cancellables)
    }
}
