// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// A string coder that records the task priority and thread QoS class its `decode` runs at.
private struct PriorityRecordingCoder: Coder {
    struct Record: Sendable, Equatable {
        let priority: TaskPriority
        let qosClass: UInt32
    }

    let records: OSAllocatedUnfairLock<[Record]>

    func encode(_ value: String) throws -> Data {
        Data(value.utf8)
    }

    func decode(_ data: Data) throws -> String {
        let record = Record(priority: Task.currentPriority, qosClass: qos_class_self().rawValue)
        records.withLock { $0.append(record) }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Creates a depot in a utility-priority task, the way an app might create it during background
/// work. The task is not awaited, so its priority is not escalated.
///
/// Utility is lower than the medium priority that observer deliveries must run at, but unlike
/// background priority, the system does not defer it for long when the machine is busy.
private func makeDepotInLowPriorityTask(_ makeDepot: @escaping @Sendable () -> Depot) async throws -> Depot {
    let box = OSAllocatedUnfairLock<Depot?>(initialState: nil)
    Task.detached(priority: .utility) {
        let depot = makeDepot()
        box.withLock { $0 = depot }
    }
    #expect(await waitUntil { box.withLock { $0 != nil } })
    return try #require(box.withLock { $0 })
}

@Suite("Observer delivery priority")
struct ObserverDeliveryPriorityTests {
    @Test("a file-backed depot created at utility priority re-reads observed values at medium priority")
    func fileBackedDeliveryRunsAtMediumPriority() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let records = OSAllocatedUnfairLock(initialState: [PriorityRecordingCoder.Record]())
        let depot = try await makeDepotInLowPriorityTask {
            Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        }
        let key = depot.register(keyPath: "value", coder: PriorityRecordingCoder(records: records))

        let updates = OSAllocatedUnfairLock(initialState: [TaskPriority]())
        let observation = depot.core.observe(
            valueFor: key,
            initialValue: false,
            update: { _ in updates.withLock { $0.append(Task.currentPriority) } },
            in: depot,
        )
        defer { observation.cancel() }

        // Transactions notify observers of modified keys, which re-read the value.
        try await depot.transaction { transaction in
            try transaction.set(value: "v1", for: key)
        }
        await depot.waitForPendingObservations()

        #expect(updates.withLock { $0 } == [.medium])
        let reads = records.withLock { $0 }
        #expect(reads.map(\.priority) == [.medium])
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            // The re-read runs on DepotKit's I/O executor, which sets the thread's QoS from the job.
            #expect(
                reads.map(\.qosClass) == [DepotIOExecutor.qosClass(forPriority: TaskPriority.medium.rawValue).rawValue]
            )
        }
    }

    @Test("a memory-only depot created at utility priority delivers observed values at medium priority")
    func memoryOnlyDeliveryRunsAtMediumPriority() async throws {
        let depot = try await makeDepotInLowPriorityTask { Depot() }
        let key = depot.register(keyPath: "value", coder: .json(String.self))

        let updates = OSAllocatedUnfairLock(initialState: [TaskPriority]())
        let observation = depot.core.observe(
            valueFor: key,
            initialValue: false,
            update: { _ in updates.withLock { $0.append(Task.currentPriority) } },
            in: depot,
        )
        defer { observation.cancel() }

        try await depot.set(value: "v1", for: key)
        await depot.waitForPendingObservations()

        #expect(updates.withLock { $0 } == [.medium])
    }
}
