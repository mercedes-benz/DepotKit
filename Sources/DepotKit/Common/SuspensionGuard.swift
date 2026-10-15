// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Starts expiring activities, during which the system does not suspend the process.
///
/// Abstracts `ProcessInfo.performExpiringActivity(withReason:using:)`, so tests can control
/// when an activity's blocks are called.
protocol ExpiringActivityProvider: Sendable {
    /// Starts an activity and calls `block` asynchronously on another thread.
    ///
    /// The activity starts when this method returns and lasts until `block`, called with
    /// `expired == false`, returns. The system may call that block late — it needs a free thread of
    /// the shared thread pool. When the system is about to suspend the process, it calls `block`
    /// (again) with `expired == true`; possibly before calling it with `expired == false`.
    func performExpiringActivity(reason: String, using block: @escaping @Sendable (_ expired: Bool) -> Void)
}

#if (os(iOS) && !targetEnvironment(macCatalyst)) || os(tvOS) || os(watchOS) || os(visionOS)
/// Expiring activities of the current process. They work in apps and in app extensions.
///
/// `performExpiringActivity` acquires the activity's assertion before it returns: a process whose
/// thread pool is busy, so that the block is not called yet, is still kept from being suspended.
struct ProcessInfoExpiringActivityProvider: ExpiringActivityProvider {
    func performExpiringActivity(reason: String, using block: @escaping @Sendable (_ expired: Bool) -> Void) {
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: block)
    }
}
#endif

/// Keeps the process from being suspended while it is inside a cross-process critical section.
///
/// A process that the system suspends while it holds or waits for coordinated access to the shared
/// lock file blocks the other processes, and the system may terminate it. Each critical section
/// therefore runs inside an expiring activity:
///
/// - A critical section never waits for the activity's block: the activity is in effect as soon as
///   the provider returned. The block — which keeps the activity alive while critical sections
///   run — needs a free thread of the shared pool; waiting for it would deadlock when critical
///   sections occupy all of them.
/// - Concurrent and nested critical sections share one activity, and so do critical sections that
///   follow each other closely. It ends when its block returns, which happens once no critical
///   section used it for a moment; until then, new critical sections join it. So only the block of
///   that activity waits for critical sections — and the block of an expired activity, until the
///   critical sections that ran at the expiration finished.
/// - When the system signals expiration, running critical sections finish (they are short), new
///   ones are refused with ``DepotError/suspensionImminent``, and the activity ends right after
///   them.
/// - After the system signalled the suspension, new critical sections are refused for a back-off
///   interval, or until the app (or the host app of an extension) enters the foreground. The
///   system keeps granting new activities to a process that keeps asking for them, so without
///   the back-off a process that writes continuously would never be suspended.
///
/// Sections nested on the same thread always join the running activity, so a critical section
/// never fails halfway.
final class SuspensionGuard: @unchecked Sendable {
    /// The guard of the current process, or `nil` on platforms whose processes are not suspended
    /// (macOS and Mac Catalyst).
    static let platform: SuspensionGuard? = {
        #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(tvOS) || os(watchOS) || os(visionOS)
        let suspensionGuard = SuspensionGuard(provider: ProcessInfoExpiringActivityProvider())
        suspensionGuard.resumeOnForegroundTransitions()
        return suspensionGuard
        #else
        return nil
        #endif
    }()

    /// Mutable state guarded by the owning guard's `condition`.
    private final class Activity: @unchecked Sendable {
        /// Whether the provider returned from starting the activity, so that it is in effect.
        var isStarted = false
        /// Whether the system signalled expiration.
        var isExpired = false
        /// The critical sections that run inside the activity.
        var users = 0
        /// When the last critical section left the activity.
        var lastLeave = ContinuousClock.now
    }

    /// How long new critical sections are refused after the system signalled the suspension.
    ///
    /// The system announces the suspension a few seconds before the process's background time
    /// runs out; the back-off outlasts that period, so that the process is suspended then.
    static let defaultBackOffInterval: Duration = .seconds(10)

    /// How long an activity outlasts its last critical section.
    ///
    /// When a process in the background holds no activity for a moment but is not suspended in
    /// that moment, the system renews its background time. Critical sections that follow each other
    /// within this interval therefore share one activity: a process that writes continuously in the
    /// background runs out of background time, and one whose critical sections are further apart is
    /// suspended between them.
    static let defaultLingerInterval: Duration = .seconds(1)

    private let provider: any ExpiringActivityProvider
    private let backOffInterval: Duration
    private let lingerInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let condition = NSCondition()
    /// The activity that new critical sections join; neither ended nor expired. Guarded by
    /// `condition`.
    private var current: Activity?
    /// Until when new critical sections are refused. Guarded by `condition`.
    private var refusedUntil: ContinuousClock.Instant?

    /// - Parameters:
    ///   - provider: Starts the expiring activities.
    ///   - backOffInterval: How long new critical sections are refused after the system signalled
    ///     the suspension.
    ///   - lingerInterval: How long an activity outlasts its last critical section.
    ///   - now: The current time, for the back-off.
    init(
        provider: any ExpiringActivityProvider,
        backOffInterval: Duration = SuspensionGuard.defaultBackOffInterval,
        lingerInterval: Duration = SuspensionGuard.defaultLingerInterval,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    ) {
        self.provider = provider
        self.backOffInterval = backOffInterval
        self.lingerInterval = lingerInterval
        self.now = now
    }

    /// Ends the back-off: the process is in the foreground again.
    func resume() {
        condition.lock()
        refusedUntil = nil
        condition.unlock()
    }

    /// Runs `body` while the process is kept from being suspended.
    ///
    /// - Throws: ``DepotError/suspensionImminent`` without running `body` when the system is
    ///   about to suspend the process, or the error thrown by `body`.
    func run<T>(_ body: () throws -> T) throws -> T {
        if Self.nestingDepth > 0 {
            return try body()
        }

        let activity = try enter()
        Self.nestingDepth += 1
        defer {
            Self.nestingDepth -= 1
            leave(activity)
        }
        return try body()
    }

    // MARK: - Private

    private func enter() throws -> Activity {
        condition.lock()
        defer { condition.unlock() }

        if let refusedUntil {
            guard now() >= refusedUntil else {
                throw DepotError.suspensionImminent
            }
            self.refusedUntil = nil
        }

        if let activity = current {
            activity.users += 1
            // The section that starts the activity waits for no thread of the shared pool.
            while !activity.isStarted {
                condition.wait()
            }
            return activity
        }

        let activity = Activity()
        activity.users = 1
        current = activity

        // The blocks may run on other threads before the provider returns; they take the lock.
        condition.unlock()
        provider.performExpiringActivity(reason: "DepotKit cross-process file access") { [self] expired in
            if expired {
                expire(activity)
            } else {
                hold(activity)
            }
        }
        condition.lock()

        activity.isStarted = true
        condition.broadcast()
        return activity
    }

    private func leave(_ activity: Activity) {
        condition.lock()
        activity.users -= 1
        if activity.users == 0 {
            activity.lastLeave = .now
            condition.broadcast()
        }
        condition.unlock()
    }

    /// Runs as the activity's non-expired block: the activity lasts until this returns.
    ///
    /// Returns once no critical section used the activity for the linger interval — right away if
    /// that passed before the system called the block — or, after the expiration, once no critical
    /// section uses it.
    private func hold(_ activity: Activity) {
        condition.lock()
        while true {
            if activity.users > 0 {
                condition.wait()
                continue
            }
            let remaining = ContinuousClock.now.duration(to: activity.lastLeave + lingerInterval)
            guard !activity.isExpired, remaining > .zero else {
                break
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: remaining / .seconds(1)))
        }

        if current === activity {
            current = nil
        }
        condition.unlock()
    }

    /// Runs as the activity's expired block.
    private func expire(_ activity: Activity) {
        condition.lock()
        let isBackingOff = refusedUntil.map { now() < $0 } ?? false
        refusedUntil = now() + backOffInterval
        // The running sections finish; `hold(_:)` ends the activity after them.
        let runningSections = activity.isExpired ? 0 : activity.users
        activity.isExpired = true
        if current === activity {
            current = nil
        }
        condition.broadcast()
        condition.unlock()

        if !isBackingOff {
            LOG(
                level: .info,
                message:
                    "DepotKit: the process is about to be suspended; finishing \(runningSections) cross-process "
                    + "critical sections and refusing new ones for \(backOffInterval)",
            )
        }
    }

    #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(tvOS) || os(watchOS) || os(visionOS)
    /// Ends the back-off when the app, or the host app of an extension, enters the foreground.
    private func resumeOnForegroundTransitions() {
        _ = NotificationCenter.default.addObserver(
            forName: .NSExtensionHostWillEnterForeground,
            object: nil,
            queue: nil,
        ) { [weak self] _ in
            self?.resume()
        }
        Task { @MainActor [weak self] in
            guard let name = ApplicationLifecycle.platform?.willEnterForeground else {
                return
            }
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.resume()
            }
        }
    }
    #endif

    // MARK: Nesting

    /// The key whose per-thread value counts the critical sections the thread is inside.
    private static let nestingDepthKey: pthread_key_t = {
        var key = pthread_key_t()
        let result = pthread_key_create(&key, nil)
        precondition(result == 0, "pthread_key_create failed with code \(result)")
        return key
    }()

    /// The number of critical sections the current thread is inside.
    private static var nestingDepth: Int {
        get { Int(bitPattern: pthread_getspecific(nestingDepthKey)) }
        set { pthread_setspecific(nestingDepthKey, UnsafeRawPointer(bitPattern: newValue)) }
    }
}
