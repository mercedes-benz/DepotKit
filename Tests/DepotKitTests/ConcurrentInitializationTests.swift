// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Depot instances that open the same multi-process store at once, as several processes do, each
/// create the metadata of an empty store. The metadata is replaced atomically and has the same
/// content for every instance, so the store must verify for all of them.
@Suite("Concurrent initialization of a shared store", .offCooperativePool)
struct ConcurrentInitializationTests {
    private static let instances = 8

    @Test("depots opened concurrently on an empty store all verify")
    func concurrentInitialization() async throws {
        for _ in 0..<10 {
            let url = BulkRemovalSupport.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: url) }
            let depots = OSAllocatedUnfairLock(initialState: [Depot]())

            await concurrentlyOnDedicatedThreads(iterations: Self.instances, threadCount: Self.instances) { _ in
                let depot = BulkRemovalSupport.makeDepot(at: url)
                depots.withLock { $0.append(depot) }
            }

            for depot in depots.withLock({ $0 }) {
                #expect(!depot.metadataCreationPending.withLock { $0 })
                try await depot.verifyIntegrity()
            }
        }
    }

    @Test("a peer's writes and resets do not fail while other depots open the store")
    func initializationDuringPeerResets() async throws {
        let url = BulkRemovalSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let peer = BulkRemovalSupport.makeDepot(at: url)
        let key = peer.register(keyPath: "value", coder: .json(Int.self))
        let depots = OSAllocatedUnfairLock(initialState: [Depot]())
        let errors = OSAllocatedUnfairLock(initialState: [String]())

        await concurrentlyOnDedicatedThreads(iterations: 4 * Self.instances + 1, threadCount: 4) { index in
            if index == 0 {
                for value in 0..<50 {
                    do {
                        try peer.set(value: value, for: key)
                        try peer.reset()
                    } catch {
                        errors.withLock { $0.append("\(error)") }
                    }
                }
            } else {
                let depot = BulkRemovalSupport.makeDepot(at: url)
                depots.withLock { $0.append(depot) }
            }
        }

        #expect(errors.withLock { $0 }.isEmpty)
        try await peer.verifyIntegrity()
        for depot in depots.withLock({ $0 }) {
            try await depot.verifyIntegrity()
        }
    }
}
