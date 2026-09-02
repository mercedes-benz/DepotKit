// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Testing
import os

@testable import DepotKit

@Suite
struct LoggingTests {
    // MARK: - Factory Methods

    @Test(".osLog() factory creates a valid sink")
    func osLogFactory() {
        let sink: any DepotKitLogSink = .osLog()
        #expect(sink is DepotKitOSLogSink)
    }

    @Test(".osLog() factory accepts custom parameters")
    func osLogFactoryCustom() {
        let sink: any DepotKitLogSink = .osLog(
            subsystem: "com.example",
            category: "Storage",
            includeSourceLocation: true,
        )
        #expect(sink is DepotKitOSLogSink)
    }

    @Test(".callback factory receives log messages")
    func callbackFactory() {
        let previousSink = DepotKitLogging.sink
        defer { DepotKitLogging.sink = previousSink }

        struct Received: Sendable {
            var level: DepotKitLogLevel?
            var message: String?
        }

        let state = OSAllocatedUnfairLock(initialState: Received())

        DepotKitLogging.sink = .callback { level, message, _, _, _ in
            let msg = message()
            state.withLock {
                $0.level = level
                $0.message = msg
            }
        }

        LOG(level: .error, message: "test message")

        let snapshot = state.withLock { $0 }
        #expect(snapshot.level == .error)
        #expect(snapshot.message == "test message")
    }

    // MARK: - Lazy Evaluation

    @Test("does not evaluate message unless sink needs it")
    func messageIsLazy() async throws {
        let previousSink = DepotKitLogging.sink
        defer { DepotKitLogging.sink = previousSink }

        var evaluated = false

        DepotKitLogging.sink = DepotKitCallbackLogSink { _, _, _, _, _ in
            // ignore
        }

        LOG(
            level: .info,
            message: {
                evaluated = true
                return "expensive"
            }(),
        )

        #expect(evaluated == false)

        evaluated = false
        DepotKitLogging.sink = DepotKitCallbackLogSink { _, message, _, _, _ in
            _ = message()
        }

        LOG(
            level: .info,
            message: {
                evaluated = true
                return "expensive"
            }(),
        )

        #expect(evaluated == true)
    }
}
