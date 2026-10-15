// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct DepotSignalTests {
    // MARK: - Basic Emit / Observe

    @Test("observer receives emitted values")
    func observerReceivesEmittedValues() {
        let signal = DepotSignal<Int>()
        let received = OSAllocatedUnfairLock(initialState: [Int]())

        signal.observe { value in
            received.withLock { $0.append(value) }
        }

        signal.emit(1)
        signal.emit(2)
        signal.emit(3)

        #expect(received.withLock { $0 } == [1, 2, 3])
    }

    @Test("multiple observers all receive each emission")
    func multipleObserversReceiveEmissions() {
        let signal = DepotSignal<String>()
        let receivedA = OSAllocatedUnfairLock(initialState: [String]())
        let receivedB = OSAllocatedUnfairLock(initialState: [String]())

        signal.observe { value in receivedA.withLock { $0.append(value) } }
        signal.observe { value in receivedB.withLock { $0.append(value) } }

        signal.emit("hello")

        #expect(receivedA.withLock { $0 } == ["hello"])
        #expect(receivedB.withLock { $0 } == ["hello"])
    }

    @Test("emit with no observers does not crash")
    func emitWithNoObservers() {
        let signal = DepotSignal<Int>()
        signal.emit(42)
    }

    @Test("void signal convenience emit works")
    func voidSignalConvenienceEmit() {
        let signal = DepotSignal<Void>()
        let count = OSAllocatedUnfairLock(initialState: 0)

        signal.observe { count.withLock { $0 += 1 } }

        signal.emit()
        signal.emit()

        #expect(count.withLock { $0 } == 2)
    }

    // MARK: - Cancellation

    @Test("cancelled observer stops receiving")
    func cancelledObserverStopsReceiving() {
        let signal = DepotSignal<Int>()
        let received = OSAllocatedUnfairLock(initialState: [Int]())

        let cancellable = signal.observe { value in
            received.withLock { $0.append(value) }
        }

        signal.emit(1)
        cancellable.cancel()
        signal.emit(2)

        #expect(received.withLock { $0 } == [1])
    }

    @Test("cancelling one observer does not affect others")
    func cancellingOneDoesNotAffectOthers() {
        let signal = DepotSignal<Int>()
        let receivedA = OSAllocatedUnfairLock(initialState: [Int]())
        let receivedB = OSAllocatedUnfairLock(initialState: [Int]())

        let cancellableA = signal.observe { value in receivedA.withLock { $0.append(value) } }
        signal.observe { value in receivedB.withLock { $0.append(value) } }

        signal.emit(1)
        cancellableA.cancel()
        signal.emit(2)

        #expect(receivedA.withLock { $0 } == [1])
        #expect(receivedB.withLock { $0 } == [1, 2])
    }

    @Test("double cancel is safe")
    func doubleCancelIsSafe() {
        let signal = DepotSignal<Int>()
        let cancellable = signal.observe { _ in }

        cancellable.cancel()
        cancellable.cancel()
    }

    // MARK: - Concurrency

    @Test("concurrent emit and observe is safe")
    func concurrentEmitAndObserveIsSafe() async {
        let signal = DepotSignal<Int>()
        let count = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        signal.observe { _ in
                            count.withLock { $0 += 1 }
                        }
                    } else {
                        signal.emit(i)
                    }
                }
            }
        }

        #expect(count.withLock { $0 } >= 0)
    }

    @Test("concurrent emit and cancel is safe")
    func concurrentEmitAndCancelIsSafe() async {
        let signal = DepotSignal<Int>()
        let cancellables = OSAllocatedUnfairLock(initialState: [any DepotCancellable]())

        for _ in 0..<50 {
            let c = signal.observe { _ in }
            cancellables.withLock { $0.append(c) }
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        signal.emit(i)
                    } else {
                        let c = cancellables.withLock { $0[i % 50] }
                        c.cancel()
                    }
                }
            }
        }
    }
}
