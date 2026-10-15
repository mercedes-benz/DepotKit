// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Removals and the subsequent pruning of empty directories must run inside the shared lock-file
/// critical section (like writes and expiry cleanup), so they cannot interleave with another depot
/// instance or process that is writing into the same directories.
@Suite("Removals run inside the cross-process critical section", .offCooperativePool)
struct RemovalCriticalSectionTests {
    typealias Support = BulkRemovalSupport

    enum Removal: String, CaseIterable, Sendable {
        case setNil
        case removeValue
        case removePattern
        case reset
        case transaction

        func perform(on depot: Depot, key: TypedDistinctKey<String>) throws {
            switch self {
            case .setNil:
                try depot.set(value: nil, for: key)
            case .removeValue:
                try depot.remove(valueFor: key)
            case .removePattern:
                try depot.remove(valuesFor: Key.from("items" / .wildcard))
            case .reset:
                try depot.reset()
            case .transaction:
                try depot.transaction { try $0.remove(valueFor: key) }
            }
        }
    }

    @Test("a removal waits for another instance's critical section before deleting", arguments: Removal.allCases)
    func removalWaitsForCriticalSection(removal: Removal) throws {
        let url = Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let holder = Support.makeDepot(at: url)
        let remover = Support.makeDepot(at: url)
        let key = Key.from("items" / "a", as: String.self)
        remover.register(key: Key.all, coder: .json(String.self))
        try remover.set(value: "a", for: key)
        let fileURL = try remover.fileURL(for: key)
        let directoryURL = fileURL.deletingLastPathComponent()

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let removerWaiting = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        remover.fileManager?.willSynchronizeWithLock = { removerWaiting.signal() }

        Thread.detachNewThread {
            do {
                try holder.fileManager?.synchronizeWithLock {
                    entered.signal()
                    release.wait()
                }
            } catch {
                Issue.record("holder failed: \(error)")
                entered.signal()
            }
        }
        #expect(entered.wait(timeout: .now() + .seconds(30)) == .success)

        Thread.detachNewThread {
            do {
                try removal.perform(on: remover, key: key)
            } catch {
                Issue.record("removal failed: \(error)")
            }
            done.signal()
        }

        let waited = removerWaiting.wait(timeout: .now() + .seconds(30)) == .success
        #expect(waited, "the removal must enter the shared critical section")
        // While the other instance holds the critical section, nothing may have been deleted.
        #expect(Support.fileExists(fileURL))
        #expect(Support.fileExists(directoryURL))

        release.signal()
        #expect(done.wait(timeout: .now() + .seconds(30)) == .success)
        #expect(!Support.fileExists(fileURL))
        #expect(!Support.fileExists(directoryURL), "empty directories are pruned")
    }
}
