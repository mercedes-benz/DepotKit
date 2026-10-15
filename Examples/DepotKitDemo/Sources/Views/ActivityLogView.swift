// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import DepotKit
import Foundation
import Observation
import SwiftUI

// MARK: - Model

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

/// Storage statistics snapshot, recomputed after every depot change.
struct DepotStats {
    var cityCount = 0
    var forecastCount = 0
    var total = Depot.DiskUsage(fileCount: 0, totalBytes: 0)
    var cities = Depot.DiskUsage(fileCount: 0, totalBytes: 0)
    var forecasts = Depot.DiskUsage(fileCount: 0, totalBytes: 0)
}

/// Builds a live activity log from `depot.values(for:)` — the lowest-level
/// observation API, useful wherever SwiftUI wrappers and Combine don't fit.
/// Also recomputes ``DepotStats`` on every change.
@MainActor
@Observable
final class ActivityLogModel {
    private(set) var entries: [ActivityEntry] = []
    private(set) var stats = DepotStats()

    @ObservationIgnored
    private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored
    private var store: DepotStore?

    func start(store: DepotStore) {
        guard tasks.isEmpty else {
            return
        }
        self.store = store

        let cityCount = (try? store.depot.count(for: store.citiesKey)) ?? 0
        log("Observation started — \(cityCount) saved cities")
        refreshStats()

        tasks.append(
            Task { [weak self, depot = store.depot, key = store.citiesKey] in
                for await result in depot.values(for: key, initialValues: false) {
                    guard let self else {
                        return
                    }
                    if case let .success(cities) = result {
                        log("Saved cities changed — now \(cities.count)")
                        refreshStats()
                    }
                }
            }
        )
        tasks.append(
            Task { [weak self, depot = store.depot, key = store.forecastsKey] in
                for await result in depot.values(for: key, initialValues: false) {
                    guard let self else {
                        return
                    }
                    if case let .success(forecasts) = result {
                        log("Forecast cache changed — \(forecasts.count) cached")
                        refreshStats()
                    }
                }
            }
        )
    }

    /// Recomputes counts and disk usage. Byte sizes include per-file headers
    /// and reflect coder effects (e.g. forecast compression).
    func refreshStats() {
        guard let store else {
            return
        }
        let depot = store.depot
        let zero = Depot.DiskUsage(fileCount: 0, totalBytes: 0)
        stats.cityCount = (try? depot.count(for: store.citiesKey)) ?? 0
        stats.forecastCount = (try? depot.count(for: store.forecastsKey)) ?? 0
        stats.total = (try? depot.diskUsage()) ?? zero
        stats.cities = (try? depot.diskUsage(under: Key.from("cities"))) ?? zero
        stats.forecasts = (try? depot.diskUsage(under: Key.from("forecasts"))) ?? zero
    }

    private func log(_ message: String) {
        entries.insert(ActivityEntry(message: message), at: 0)
    }

    deinit {
        for task in tasks {
            task.cancel()
        }
    }
}

// MARK: - Storage breakdown

/// Proportional color bar and stat grid showing per-category disk usage.
private struct StorageBreakdownView: View {
    let stats: DepotStats

    private var totalKnown: Int64 {
        max(stats.cities.totalBytes + stats.forecasts.totalBytes, 1)
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    let citiesFraction = CGFloat(stats.cities.totalBytes) / CGFloat(totalKnown)
                    let forecastFraction = CGFloat(stats.forecasts.totalBytes) / CGFloat(totalKnown)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.depotAmber)
                        .frame(width: max(geo.size.width * citiesFraction, 4))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue)
                        .frame(width: max(geo.size.width * forecastFraction, 4))
                }
            }
            .frame(height: 10)
            .background(.fill.quaternary, in: Capsule())

            HStack(spacing: 0) {
                StatCell(
                    value: "\(stats.cityCount)",
                    label: "Cities",
                    detail: stats.cities.totalBytes,
                    color: .depotAmber
                )
                Divider().frame(height: 32)
                StatCell(
                    value: "\(stats.forecastCount)",
                    label: "Forecasts",
                    detail: stats.forecasts.totalBytes,
                    color: .blue
                )
                Divider().frame(height: 32)
                StatCell(
                    value: "\(stats.total.fileCount)",
                    label: "Files",
                    detail: nil,
                    color: .secondary
                )
                Divider().frame(height: 32)
                StatCell(
                    value: stats.total.totalBytes,
                    label: "Total",
                    detail: nil,
                    color: .secondary
                )
            }
        }
    }
}

private struct StatCell: View {
    let value: String
    let label: String
    let detail: Int64?
    let color: Color

    init(value: String, label: String, detail: Int64?, color: Color) {
        self.value = value
        self.label = label
        self.detail = detail
        self.color = color
    }

    init(value: Int64, label: String, detail: Int64?, color: Color) {
        self.value = ByteCountFormatStyle(style: .file).format(value)
        self.label = label
        self.detail = detail
        self.color = color
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail, format: .byteCount(style: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - View

/// Live log of depot changes, storage breakdown, and a Combine-driven
/// "last refresh" timestamp.
struct ActivityLogView: View {
    let store: DepotStore

    @State
    private var model = ActivityLogModel()
    @State
    private var refreshStatus: RefreshStatusModel

    init(store: DepotStore) {
        self.store = store
        _refreshStatus = State(initialValue: RefreshStatusModel(store: store))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(Color.depotAmber)
                            .frame(width: 24)
                        Text("Last refresh")
                        Spacer()
                        if let date = refreshStatus.lastRefresh {
                            Text(date, format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("never")
                                .foregroundStyle(.tertiary)
                        }
                    }
                } footer: {
                    DepotAnnotation("published(valueFor:)")
                        .padding(.top, 2)
                }

                Section {
                    StorageBreakdownView(stats: model.stats)
                } header: {
                    Text("Storage")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        DepotAnnotation("diskUsage(under:) · count(for:)")
                        Text(
                            "Sizes include the per-file DepotKit header; forecasts are zlib-compressed on disk."
                        )
                    }
                    .padding(.top, 2)
                }

                Section {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(index == 0 ? Color.depotAmber : Color.gray.opacity(0.4))
                                    .frame(width: 10, height: 10)
                                    .padding(.top, 5)
                                if index < model.entries.count - 1 {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(width: 2)
                                        .frame(maxHeight: .infinity)
                                }
                            }
                            .frame(width: 14)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message)
                                    .font(.callout)
                                Text(entry.date, format: .dateTime.hour().minute().second())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 4)
                        }
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Depot Activity")
                } footer: {
                    DepotAnnotation("depot.values(for:)")
                        .padding(.top, 2)
                }
            }
            .navigationTitle("Activity")
            .task {
                model.start(store: store)
            }
        }
    }
}
