// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// The task executor that runs the synchronous storage work of file-backed depots.
///
/// Storage work can block for a long time: file I/O, waits for a depot's reader/writer lock, and
/// `NSFileCoordinator` waits, which in multi-process depots last as long as another process holds
/// the shared lock file. Swift concurrency's cooperative pool has only one thread per CPU core and
/// does not add threads while its threads are blocked, so blocking work there stalls every other
/// task of the process, including main-actor work that waits for a `Task.sleep` wake-up.
///
/// Tasks prefer this executor (SE-0417) while they run storage work, so the work stays in the
/// calling task (task-local values, priority, cancellation) but runs on threads this executor owns.
/// A thread is started whenever a job arrives and no thread is idle, so a job that waits for another
/// process does not hold up the work of other depots. Each depot already limits its own concurrent
/// async operations (`maximumConcurrentTasks`). Threads exit after they have been idle for a while.
///
/// ## Priority Limitations
///
/// A thread takes on the QoS class of a job's priority when the job starts. Unlike Swift's global
/// executor, this executor does not raise that QoS when a higher-priority task later awaits the task
/// running the job (priority escalation), and jobs that wait at the thread limit run in arrival
/// order regardless of their priority. A possible solution: run the work of `performBlocking` and
/// `withSemaphore` in `withTaskPriorityEscalationHandler` (SE-0462; iOS, macOS, tvOS, watchOS, and
/// visionOS 26 and later), apply `pthread_override_qos_class_start_np` to the thread running the
/// job in the handler, end the override with `pthread_override_qos_class_end_np` when the job
/// finishes, and order waiting jobs by priority. Blocking waits for a depot's reader/writer lock or
/// for another process's file coordination are invisible to Swift's escalation and would remain
/// unaffected.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
final class DepotIOExecutor: TaskExecutor, @unchecked Sendable {
    /// The executor that all depots of the process share.
    static let shared = DepotIOExecutor()

    /// The name of the executor's threads.
    static let threadName = "DepotKit.io"

    private let maximumThreadCount: Int
    private let idleTimeout: TimeInterval
    private let condition = NSCondition()

    // Guarded by `condition`.
    private var jobs: [UnownedJob] = []
    private var nextJobIndex = 0
    private var threadCount = 0
    /// Threads that wait for jobs in `runJobs()`.
    private var waitingThreadCount = 0
    /// Waiting threads that were signaled for a new job and have not woken up yet.
    private var signaledThreadCount = 0

    /// - Parameters:
    ///   - maximumThreadCount: The most threads that run at the same time; further jobs wait until a
    ///     thread finishes its job. It is a safety limit that depots normally do not reach.
    ///   - idleTimeout: How long a thread waits for a job before it exits.
    init(maximumThreadCount: Int = 64, idleTimeout: TimeInterval = 10) {
        precondition(maximumThreadCount >= 1, "DepotIOExecutor needs at least one thread")
        self.maximumThreadCount = maximumThreadCount
        self.idleTimeout = idleTimeout
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)

        condition.lock()
        jobs.append(job)
        let startsThread: Bool
        if waitingThreadCount > signaledThreadCount {
            // Counting the signaled threads makes jobs that arrive before a signaled thread woke up
            // start (or wake) further threads instead of queueing behind that one.
            signaledThreadCount += 1
            condition.signal()
            startsThread = false
        } else if threadCount < maximumThreadCount {
            threadCount += 1
            startsThread = true
        } else {
            // The next thread that finishes its job takes this one.
            startsThread = false
        }
        condition.unlock()

        if startsThread {
            let thread = Thread { [self] in
                runJobs()
            }
            thread.name = Self.threadName
            thread.start()
        }
    }

    /// The number of threads that are running, for tests.
    var currentThreadCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return threadCount
    }

    private func runJobs() {
        var currentQoS = qos_class_self()
        while let job = nextJob() {
            let qos = Self.qosClass(forPriority: job.priority.rawValue)
            if qos != currentQoS {
                pthread_set_qos_class_self_np(qos, 0)
                currentQoS = qos
            }
            // The Swift runtime drains an autorelease pool around the job, so objects that Foundation
            // autoreleases (for example, in every file coordination) do not pile up on this thread.
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    /// Returns the next job, or `nil` (after removing the thread from the count) when the thread has
    /// been idle for `idleTimeout` and should exit.
    private func nextJob() -> UnownedJob? {
        condition.lock()
        defer { condition.unlock() }

        let deadline = Date(timeIntervalSinceNow: idleTimeout)
        while nextJobIndex == jobs.count {
            jobs.removeAll(keepingCapacity: true)
            nextJobIndex = 0

            waitingThreadCount += 1
            let timedOut = !condition.wait(until: deadline)
            waitingThreadCount -= 1
            // Signals and wake-ups (also spurious ones and timeouts) are not matched to threads, so
            // any thread that wakes up uses up one outstanding signal. Whichever thread wakes up
            // first takes the job, and the job queue is checked before a thread exits.
            if signaledThreadCount > 0 {
                signaledThreadCount -= 1
            }

            if timedOut, nextJobIndex == jobs.count {
                threadCount -= 1
                return nil
            }
        }

        let job = jobs[nextJobIndex]
        nextJobIndex += 1
        // Keep a long-busy queue from growing without bound.
        if nextJobIndex >= 64, nextJobIndex * 2 >= jobs.count {
            jobs.removeFirst(nextJobIndex)
            nextJobIndex = 0
        }
        return job
    }

    /// The quality-of-service class that a job of the given priority runs at.
    static func qosClass(forPriority rawValue: JobPriority.RawValue) -> qos_class_t {
        if rawValue == 0 || rawValue == TaskPriority.medium.rawValue {
            // Jobs without a priority run at the default QoS, like on the cooperative pool.
            return QOS_CLASS_DEFAULT
        } else if rawValue > TaskPriority.userInitiated.rawValue {
            return QOS_CLASS_USER_INTERACTIVE
        } else if rawValue > TaskPriority.medium.rawValue {
            return QOS_CLASS_USER_INITIATED
        } else if rawValue > TaskPriority.utility.rawValue {
            return QOS_CLASS_DEFAULT
        } else if rawValue > TaskPriority.background.rawValue {
            return QOS_CLASS_UTILITY
        } else {
            return QOS_CLASS_BACKGROUND
        }
    }
}

/// Starts a task that prefers ``DepotIOExecutor`` where it is available, so that the storage work
/// it runs does not block Swift concurrency's cooperative pool.
///
/// On earlier systems it starts a plain task. Either way the task does not run on the caller's actor.
@discardableResult
func startIOTask(
    priority: TaskPriority? = nil,
    _ operation: @escaping @Sendable @concurrent () async -> Void,
) -> Task<Void, Never> {
    if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
        return Task(executorPreference: DepotIOExecutor.shared, priority: priority, operation: operation)
    }
    return Task(priority: priority, operation: operation)
}

/// Like ``startIOTask(priority:_:)``, but starts a detached task.
@discardableResult
func startDetachedIOTask(
    priority: TaskPriority? = nil,
    _ operation: @escaping @Sendable @concurrent () async -> Void,
) -> Task<Void, Never> {
    if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
        return Task.detached(executorPreference: DepotIOExecutor.shared, priority: priority, operation: operation)
    }
    return Task.detached(priority: priority, operation: operation)
}
