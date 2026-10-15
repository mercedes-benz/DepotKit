// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if (os(iOS) && !targetEnvironment(macCatalyst)) || os(tvOS) || os(watchOS) || os(visionOS)
import Foundation
import Testing
import os

@testable import DepotKit

// This suite must not use the `.offCooperativePool` trait: it occupies the cooperative pool on
// purpose, with the platform's real suspension guard.

/// Blocks the calling thread until `count` callers arrived, or for at most two seconds, so that
/// the callers occupy that many threads of the cooperative pool at the same time.
private func occupyPoolThread(arrived: OSAllocatedUnfairLock<Int>, count: Int) {
    arrived.withLock { $0 += 1 }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while arrived.withLock({ $0 }) < count, ContinuousClock.now < deadline {
        usleep(1000)
    }
}

/// Opens a multi-process depot and runs synchronous cross-process operations on it.
///
/// Every caller uses its own directory: file presenters of other depots on the same lock file
/// would make each write wait for their callbacks.
private func runSynchronousOperations(at url: URL, index: Int) throws {
    defer { try? FileManager.default.removeItem(at: url) }
    let depot = Depot(
        configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled),
        overrides: .init(initSweepDelay: .seconds(3600)),
    )
    let key = depot.register(keyPath: "value", coder: .json(Int.self))
    try depot.addFilePresenter()
    try depot.set(value: index, for: key)
    try depot.transaction { try $0.set(value: index + 1, for: key) }
    try depot.removeFilePresenter()
}

@Suite("Cross-process critical sections need no free thread of the shared pool")
struct SuspensionGuardPoolExhaustionTests {
    @Test("synchronous multi-process operations on every thread of the cooperative pool complete")
    func saturatedCooperativePool() async throws {
        #expect(SuspensionGuard.platform != nil)
        let width = ProcessInfo.processInfo.activeProcessorCount
        let arrived = OSAllocatedUnfairLock(initialState: 0)
        let errors = OSAllocatedUnfairLock<[String]>(initialState: [])

        let start = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<(width * 2) {
                group.addTask {
                    occupyPoolThread(arrived: arrived, count: width)
                    do {
                        try runSynchronousOperations(
                            at: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                            index: index,
                        )
                    } catch {
                        errors.withLock { $0.append("\(error)") }
                    }
                }
            }
        }
        let elapsed = start.duration(to: .now)

        #expect(errors.withLock { $0 }.isEmpty)
        // Critical sections that waited for the activity's block, which needs a free thread of the
        // pool, waited until the activity expired (about 30 seconds in a simulator's test process),
        // or forever in a foreground app.
        #expect(elapsed < .seconds(20), "took \(elapsed)")
    }
}
#endif
