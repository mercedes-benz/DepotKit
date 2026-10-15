// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// An observer's initial delivery can run before the `observe` call that scheduled it returns.
/// A write committed after that delivery read the value must still reach the observer.
@Suite("Observer registration race", .offCooperativePool)
struct ObserverRegistrationRaceTests {
    typealias ObserverKind = ObserverReentrancyAndConvergenceTests.ObserverKind

    enum Writer: String, CaseIterable, Sendable {
        /// The initial delivery's callback writes the next value.
        case callback
        /// Another caller writes the next value right after the initial delivery.
        case concurrent
    }

    @Test(
        "a write after the initial delivery reaches an observer whose observe call has not returned yet",
        arguments: [false, true],
        ObserverKind.allCases,
    )
    func writeAfterInitialDelivery(fileBacked: Bool, kind: ObserverKind) async throws {
        for writer in Writer.allCases {
            try await run(fileBacked: fileBacked, kind: kind, writer: writer)
        }
    }

    private func run(fileBacked: Bool, kind: ObserverKind, writer: Writer) async throws {
        let depot = fileBacked ? Depot.temporary(memoryCache: .default) : Depot()
        defer {
            if let url = depot.configuration.directoryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let key = depot.register(keyPath: "value", coder: .json(Int.self))
        try await depot.set(value: 1, for: key)

        let log = DeliveryLog<Int?>()
        let errors = DeliveryLog<String>()
        let initialDelivered = DispatchSemaphore(value: 0)

        // Holds `observe` until the initial delivery (and the callback's write) has completed.
        depot.core.setObserverAddedHook {
            guard initialDelivered.wait(timeout: .now() + .seconds(30)) == .success else {
                errors.append("the initial delivery did not run")
                return
            }
            if writer == .concurrent {
                do {
                    try depot.set(value: 2, for: key)
                } catch {
                    errors.append("\(error)")
                }
            }
        }

        // The hook blocks, so call `observe` off the cooperative pool and the I/O executor.
        let cancellable = await onDedicatedThread {
            kind.observe(key, initialValue: true, in: depot) { result in
                let value: Int?
                do {
                    value = try result.get()
                } catch {
                    errors.append("\(error)")
                    return
                }
                log.append(value)
                guard value == 1 else {
                    return
                }
                if writer == .callback {
                    do {
                        try depot.set(value: 2, for: key)
                    } catch {
                        errors.append("\(error)")
                    }
                }
                initialDelivered.signal()
            }
        }
        defer { cancellable.cancel() }
        depot.core.setObserverAddedHook(nil)

        await depot.waitForPendingObservations()

        let context = "fileBacked: \(fileBacked), kind: \(kind), writer: \(writer)"
        #expect(errors.all.isEmpty, "\(context)")
        #expect(try await depot.get(valueFor: key) == 2, "\(context)")
        #expect(log.all == [1, 2], "\(context)")
    }
}
