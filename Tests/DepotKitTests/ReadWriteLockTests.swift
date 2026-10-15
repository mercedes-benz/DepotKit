// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct ReadWriteLockTests {
    @Test("withReadLock returns the closure result")
    func withReadLockReturnsClosureResult() {
        let lock = ReadWriteLock()
        let result = lock.withReadLock { 42 }
        #expect(result == 42)
    }

    @Test("withWriteLock returns the closure result")
    func withWriteLockReturnsClosureResult() {
        let lock = ReadWriteLock()
        let result = lock.withWriteLock { "hello" }
        #expect(result == "hello")
    }

    @Test("withReadLock propagates thrown errors")
    func withReadLockPropagatesThrownErrors() {
        let lock = ReadWriteLock()
        #expect(throws: TestError.self) {
            try lock.withReadLock { throw TestError.intentional }
        }
    }

    @Test("withWriteLock propagates thrown errors")
    func withWriteLockPropagatesThrownErrors() {
        let lock = ReadWriteLock()
        #expect(throws: TestError.self) {
            try lock.withWriteLock { throw TestError.intentional }
        }
    }

    @Test("lock is usable after read closure throws")
    func lockIsUsableAfterReadClosureThrows() {
        let lock = ReadWriteLock()
        _ = try? lock.withReadLock { throw TestError.intentional }
        let result = lock.withWriteLock { "recovered" }
        #expect(result == "recovered")
    }

    @Test("lock is usable after write closure throws")
    func lockIsUsableAfterWriteClosureThrows() {
        let lock = ReadWriteLock()
        _ = try? lock.withWriteLock { throw TestError.intentional }
        let result = lock.withReadLock { "recovered" }
        #expect(result == "recovered")
    }

    // The tests below block while they wait for other threads. They run on dedicated threads (see
    // `onDedicatedThread`) so they neither occupy cooperative-pool threads nor depend on GCD worker
    // threads, which are not granted while the pool is saturated by parallel tests.

    @Test("multiple concurrent readers do not block each other")
    func multipleConcurrentReadersDoNotBlockEachOther() async {
        let lock = ReadWriteLock()
        let readerCount = 8
        let peakConcurrency = OSAllocatedUnfairLock(initialState: 0)
        let maxConcurrency = OSAllocatedUnfairLock(initialState: 0)

        let finished = await onDedicatedThread {
            let group = DispatchGroup()

            for _ in 0..<readerCount {
                group.enter()
                Thread.detachNewThread {
                    lock.withReadLock {
                        let current = peakConcurrency.withLock { value in
                            value += 1
                            return value
                        }
                        maxConcurrency.withLock { $0 = max($0, current) }
                        Thread.sleep(forTimeInterval: 0.01)
                        peakConcurrency.withLock { $0 -= 1 }
                    }
                    group.leave()
                }
            }

            return group.wait(timeout: .now() + 30)
        }
        #expect(finished == .success)
        let observed = maxConcurrency.withLock { $0 }
        #expect(observed > 1, "Multiple readers should hold the lock concurrently (observed: \(observed))")
    }

    @Test("writer excludes readers")
    func writerExcludesReaders() async {
        let lock = ReadWriteLock()
        let writerStarted = DispatchSemaphore(value: 0)
        let writerFinish = DispatchSemaphore(value: 0)
        let readerEnteredDuringWrite = OSAllocatedUnfairLock(initialState: false)

        let (entered, enteredAfter) = await onDedicatedThread {
            Thread.detachNewThread {
                lock.withWriteLock {
                    writerStarted.signal()
                    writerFinish.wait()
                }
            }

            writerStarted.wait()

            Thread.detachNewThread {
                lock.withReadLock {
                    readerEnteredDuringWrite.withLock { $0 = true }
                }
            }

            Thread.sleep(forTimeInterval: 0.05)
            let entered = readerEnteredDuringWrite.withLock { $0 }

            writerFinish.signal()
            return (entered, Self.waitForFlag(readerEnteredDuringWrite))
        }
        #expect(entered == false, "Reader must not enter while writer holds lock")
        #expect(enteredAfter == true, "Reader should enter after writer releases")
    }

    @Test("writer excludes other writers")
    func writerExcludesOtherWriters() async {
        let lock = ReadWriteLock()
        let firstWriterStarted = DispatchSemaphore(value: 0)
        let firstWriterFinish = DispatchSemaphore(value: 0)
        let secondWriterEntered = OSAllocatedUnfairLock(initialState: false)

        let (entered, enteredAfter) = await onDedicatedThread {
            Thread.detachNewThread {
                lock.withWriteLock {
                    firstWriterStarted.signal()
                    firstWriterFinish.wait()
                }
            }

            firstWriterStarted.wait()

            Thread.detachNewThread {
                lock.withWriteLock {
                    secondWriterEntered.withLock { $0 = true }
                }
            }

            Thread.sleep(forTimeInterval: 0.05)
            let entered = secondWriterEntered.withLock { $0 }

            firstWriterFinish.signal()
            return (entered, Self.waitForFlag(secondWriterEntered))
        }
        #expect(entered == false, "Second writer must not enter while first holds lock")
        #expect(enteredAfter == true, "Second writer should enter after first releases")
    }

    @Test("readers exclude writer")
    func readersExcludeWriter() async {
        let lock = ReadWriteLock()
        let readerStarted = DispatchSemaphore(value: 0)
        let readerFinish = DispatchSemaphore(value: 0)
        let writerEntered = OSAllocatedUnfairLock(initialState: false)

        let (entered, enteredAfter) = await onDedicatedThread {
            Thread.detachNewThread {
                lock.withReadLock {
                    readerStarted.signal()
                    readerFinish.wait()
                }
            }

            readerStarted.wait()

            Thread.detachNewThread {
                lock.withWriteLock {
                    writerEntered.withLock { $0 = true }
                }
            }

            Thread.sleep(forTimeInterval: 0.05)
            let entered = writerEntered.withLock { $0 }

            readerFinish.signal()
            return (entered, Self.waitForFlag(writerEntered))
        }
        #expect(entered == false, "Writer must not enter while reader holds lock")
        #expect(enteredAfter == true, "Writer should enter after reader releases")
    }

    @Test("concurrent reads and writes maintain data integrity")
    func concurrentReadsAndWritesMaintainDataIntegrity() async {
        let lock = ReadWriteLock()
        let value = OSAllocatedUnfairLock(initialState: 0)
        let iterations = 200
        let writerCount = 4
        let readerCount = 8

        let finished = await onDedicatedThread {
            let group = DispatchGroup()

            for _ in 0..<writerCount {
                group.enter()
                Thread.detachNewThread {
                    for _ in 0..<iterations {
                        lock.withWriteLock {
                            value.withLock { $0 += 1 }
                        }
                    }
                    group.leave()
                }
            }

            for _ in 0..<readerCount {
                group.enter()
                Thread.detachNewThread {
                    for _ in 0..<iterations {
                        let read = lock.withReadLock { value.withLock { $0 } }
                        _ = read
                    }
                    group.leave()
                }
            }

            return group.wait(timeout: .now() + 30)
        }
        #expect(finished == .success)
        #expect(value.withLock { $0 } == writerCount * iterations)
    }

    @Test("stress: rapid lock/unlock cycles do not lose writes")
    func stressRapidLockUnlockCyclesDoNotLoseWrites() async {
        let lock = ReadWriteLock()
        let array = OSAllocatedUnfairLock(initialState: [Int]())
        let iterations = 200
        let threadCount = 8

        let finished = await onDedicatedThread {
            let group = DispatchGroup()

            for t in 0..<threadCount {
                group.enter()
                Thread.detachNewThread {
                    for i in 0..<iterations {
                        lock.withWriteLock {
                            array.withLock { $0.append(t * iterations + i) }
                        }
                    }
                    group.leave()
                }
            }

            return group.wait(timeout: .now() + 30)
        }
        #expect(finished == .success)
        let finalArray = array.withLock { $0 }
        #expect(finalArray.count == threadCount * iterations)
        #expect(Set(finalArray).count == threadCount * iterations, "All values should be unique — no lost writes")
    }

    /// Waits (as an upper bound, not a latency requirement) until `flag` is set.
    private static func waitForFlag(_ flag: OSAllocatedUnfairLock<Bool>, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !flag.withLock({ $0 }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        return flag.withLock { $0 }
    }
}

private enum TestError: Error {
    case intentional
}
