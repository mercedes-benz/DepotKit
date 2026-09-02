// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import DepotKit
import DepotKitObservation
import SwiftUI

/// City search backed by the *memory-only* depot. Results are written to
/// `store.searchDepot` (no name, no files) and vanish on quit — contrast
/// this with the persistent named depot used for saved cities.
struct CitySearchView: View {
    let store: DepotStore

    @DepotValues
    private var results: [City]

    @State
    private var query = ""
    @FocusState
    private var queryFocused: Bool
    @Environment(\.dismiss)
    private var dismiss

    private let service = WeatherService()

    init(store: DepotStore) {
        self.store = store
        _results = DepotValues(key: store.searchResultsKey, depot: store.searchDepot)
    }

    private var savedCityIDs: Set<String> {
        Set(store.savedCities().map(\.id))
    }

    var body: some View {
        NavigationStack {
            List {
                // Plain TextField instead of .searchable — focus is unreliable
                // in sheets on macOS.
                TextField("Filter by city or country", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                if results.isEmpty && !query.isEmpty {
                    Text("No matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(results.sorted { $0.name < $1.name }) { city in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(city.name)
                                .font(.body.weight(.medium))
                            Text(city.country)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if savedCityIDs.contains(city.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .imageScale(.large)
                        } else {
                            Button {
                                store.add(city)
                                dismiss()
                            } label: {
                                Text("Add")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(Color.depotAmber, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .onChange(of: query) {
                store.updateSearchResults(service.search(matching: query))
            }
            .onAppear {
                // Seed with the full catalog so the sheet opens populated.
                store.updateSearchResults(service.search(matching: query))
                queryFocused = true
            }
            .navigationTitle("Add City")
            .toolbar {
                Button("Done") {
                    dismiss()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}
