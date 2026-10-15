// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Regression tests: expiry cleanup must never delete a fresh replacement that another
/// depot instance (or process) writes between the expiry inspection and the deletion.
///
/// The deterministic tests use two depot instances in one process. Both participate in the same
/// cross-process critical section (coordinated access to the shared lock file), so they exercise
/// the same protocol that app/extension processes use. The macOS-only integration test spawns a
/// real second process that performs its write under the same file coordination.
@Suite("Expiry cleanup vs. concurrent replacement", .offCooperativePool)
struct ExpiryCoordinationTests {
    private static let start = Date(timeIntervalSince1970: 1_000_000)

    private static func configuration(_ url: URL) -> DepotConfiguration {
        .init(directoryURL: url, enableMultiProcessSupport: true)
    }

    /// Creates the writer depot (B) and stores an expired value through it.
    private static func makeWriterWithExpiredValue(
        at url: URL,
    ) throws -> (depot: Depot, key: TypedDistinctKey<String>, clock: MockClock) {
        let clock = MockClock(now: start)
        let depot = Depot(
            configuration: configuration(url),
            overrides: .init(clock: clock, initSweepDelay: .seconds(3600)),
        )
        let key = depot.register(keyPath: "token", coder: .json() as AnyCoder<String>, expiry: .seconds(10))
        try depot.set(value: "stale", for: key)

        // The fresh replacement written later must not be expired from the cleaning depot's point of view.
        clock.set(start.addingTimeInterval(100))
        return (depot, key, clock)
    }

    /// Hook for the cleaning depot (A): when it is about to delete the expired file, depot B
    /// starts replacing the value with a fresh one.
    ///
    /// The hook runs inside A's cross-process critical section and checks that B is excluded from
    /// it: it waits (generously bounded) until B is about to request the critical section, then
    /// gives B ``exclusionWindow`` to enter it. Without exclusion, B enters within milliseconds and
    /// the hook records a problem, so the tests fail reliably instead of depending on scheduling.
    private final class ReplacementHook: Sendable {
        /// How long B may take to (wrongly) enter the critical section while A holds it.
        static let exclusionWindow: DispatchTimeInterval = .seconds(2)

        private let writer: Depot
        private let key: TypedDistinctKey<String>
        private let fired = OSAllocatedUnfairLock(initialState: false)
        private let waitingForLock = DispatchSemaphore(value: 0)
        private let acquiredLock = DispatchSemaphore(value: 0)
        private let recordedProblems = OSAllocatedUnfairLock<[String]>(initialState: [])
        let replacementDone = DispatchSemaphore(value: 0)

        init(writer: Depot, key: TypedDistinctKey<String>) {
            self.writer = writer
            self.key = key
        }

        /// Problems found while the hook ran (outside the test's task), evaluated by the test.
        var problems: [String] {
            recordedProblems.withLock { $0 }
        }

        var hasFired: Bool {
            fired.withLock { $0 }
        }

        func willRemoveExpiredFile(_ fileURL: URL) {
            let isFirst = fired.withLock { fired in
                defer { fired = true }
                return !fired
            }
            guard isFirst else {
                return
            }

            writer.fileManager?.willSynchronizeWithLock = { [waitingForLock] in waitingForLock.signal() }
            writer.fileManager?.didAcquireLock = { [acquiredLock] in acquiredLock.signal() }
            Thread.detachNewThread { [writer, key, recordedProblems, replacementDone] in
                do {
                    try writer.set(value: "fresh", for: key)
                } catch {
                    recordedProblems.withLock { $0.append("replacement write failed: \(error)") }
                }
                replacementDone.signal()
            }

            guard waitingForLock.wait(timeout: .now() + .seconds(30)) == .success else {
                recordedProblems.withLock { $0.append("the replacement write never requested the critical section") }
                return
            }
            if acquiredLock.wait(timeout: .now() + Self.exclusionWindow) == .success {
                recordedProblems.withLock {
                    $0.append("the replacement write entered the critical section while expiry cleanup held it")
                }
            }
        }
    }

    private static func expectFreshValueSurvived(
        cleaner: Depot,
        writer: Depot,
        key: TypedDistinctKey<String>,
        url: URL,
        hook: ReplacementHook,
    ) throws {
        #expect(hook.hasFired, "expiry cleanup did not inspect the expired file")
        #expect(hook.replacementDone.wait(timeout: .now() + .seconds(30)) == .success, "replacement write hung")
        #expect(hook.problems.isEmpty, "\(hook.problems)")

        let fileURL = try writer.fileURL(for: key)
        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

        // The cleaner removed the expired value and must pick up the replacement via change detection.
        try cleaner.checkForExternalChanges()
        #expect(try cleaner.get(valueFor: key) == "fresh")
        #expect(try writer.get(valueFor: key) == "fresh")
    }

    @Test("explicit removeExpired does not delete a replacement written between inspection and deletion")
    func explicitCleanupPreservesFreshReplacement() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let (writer, key, _) = try Self.makeWriterWithExpiredValue(at: url)

        let hook = ReplacementHook(writer: writer, key: key)
        var hooks = Depot.TestHooks()
        hooks.willRemoveExpiredFile = { hook.willRemoveExpiredFile($0) }
        let cleaner = Depot(
            configuration: Self.configuration(url),
            overrides: .init(
                clock: MockClock(now: Self.start.addingTimeInterval(100)),
                initSweepDelay: .seconds(3600),
                testHooks: hooks,
            ),
        )
        _ = cleaner.register(keyPath: "token", coder: .json() as AnyCoder<String>, expiry: .seconds(10))

        let removed = try cleaner.removeExpired()
        #expect(removed == 1)

        try Self.expectFreshValueSurvived(cleaner: cleaner, writer: writer, key: key, url: url, hook: hook)
    }

    @Test("automatic startup sweep does not delete a replacement written between inspection and deletion")
    func startupSweepPreservesFreshReplacement() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let (writer, key, _) = try Self.makeWriterWithExpiredValue(at: url)

        let hook = ReplacementHook(writer: writer, key: key)
        var hooks = Depot.TestHooks()
        hooks.willRemoveExpiredFile = { hook.willRemoveExpiredFile($0) }
        let cleaner = Depot(
            configuration: Self.configuration(url),
            overrides: .init(
                clock: MockClock(now: Self.start.addingTimeInterval(100)),
                initSweepDelay: .zero,
                testHooks: hooks,
            ),
        )
        _ = cleaner.register(keyPath: "token", coder: .json() as AnyCoder<String>, expiry: .seconds(10))

        await cleaner.waitForInitSweep()

        try Self.expectFreshValueSurvived(cleaner: cleaner, writer: writer, key: key, url: url, hook: hook)
    }

    @Test("writes and expiry cleanup in multi-process depots run inside the shared lock-file critical section")
    func writesAndCleanupSynchronizeOnLockFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let clock = MockClock(now: Self.start)
        let depot = Depot(
            configuration: Self.configuration(url),
            overrides: .init(clock: clock, initSweepDelay: .seconds(3600)),
        )
        let key = depot.register(keyPath: "token", coder: .json() as AnyCoder<String>, expiry: .seconds(10))

        let synchronizations = OSAllocatedUnfairLock(initialState: 0)
        depot.fileManager?.willSynchronizeWithLock = { synchronizations.withLock { $0 += 1 } }

        try depot.set(value: "value", for: key)
        #expect(synchronizations.withLock { $0 } == 1)

        try depot.transaction { transaction in
            try transaction.set(value: "other", for: key)
        }
        #expect(synchronizations.withLock { $0 } == 2)

        clock.advance(by: 100)
        #expect(try depot.removeExpired() == 1)
        #expect(synchronizations.withLock { $0 } == 3)
    }

    @Test("a remove-all transaction inside the critical section completes and keeps the depot usable")
    func removeAllTransactionInsideCriticalSection() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: Self.configuration(url),
            overrides: .init(initSweepDelay: .seconds(3600)),
        )
        let key = depot.register(keyPath: "token", coder: .json() as AnyCoder<String>)
        try depot.set(value: "old", for: key)

        let done = DispatchSemaphore(value: 0)
        let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
        Thread.detachNewThread {
            do {
                try depot.transaction { transaction in
                    try transaction.removeAll()
                    try transaction.set(value: "new", for: key)
                }
            } catch {
                failure.withLock { $0 = "\(error)" }
            }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + .seconds(60)) == .success, "transaction deadlocked")
        #expect(failure.withLock { $0 } == nil)

        #expect(try depot.get(valueFor: key) == "new")
        try depot.verifyIntegrity()
        try depot.set(value: "after", for: key)
        #expect(try depot.removeExpired() == 0)
    }

    #if os(macOS)
    /// Spawns a separate process that atomically replaces the expired file while holding the same
    /// `NSFileCoordinator` write coordination on the shared lock file that DepotKit writers use.
    ///
    /// The helper is a JavaScript-for-Automation script so no extra build product is needed.
    @Test(
        "cross-process replacement during explicit cleanup survives",
        .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript")),
    )
    func crossProcessReplacementSurvives() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let sourceURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)

        // Prepare the fresh file contents with a separate depot.
        let sourceDepot = Depot(
            configuration: .init(directoryURL: sourceURL),
            overrides: .init(clock: MockClock(now: Self.start.addingTimeInterval(100)), initSweepDelay: .seconds(3600)),
        )
        let sourceKey = sourceDepot.register(keyPath: "token", coder: .json() as AnyCoder<String>, expiry: .seconds(10))
        try await sourceDepot.set(value: "fresh", for: sourceKey)

        let (writer, key, _) = try Self.makeWriterWithExpiredValue(at: url)
        _ = writer

        let lockURL = url.appending(component: "\(Depot.HiddenKeyPrefix)LOCK")
        let targetURL = try writer.fileURL(for: key)
        let helper = try CoordinatedReplaceHelper(
            lockURL: lockURL,
            sourceURL: try sourceDepot.fileURL(for: sourceKey),
            targetURL: targetURL,
        )

        var hooks = Depot.TestHooks()
        hooks.willRemoveExpiredFile = { _ in
            helper.startAndWaitUntilCoordinating()
        }
        let cleaner = Depot(
            configuration: Self.configuration(url),
            overrides: .init(
                clock: MockClock(now: Self.start.addingTimeInterval(100)),
                initSweepDelay: .seconds(3600),
                testHooks: hooks,
            ),
        )
        _ = cleaner.register(keyPath: "token", coder: .json() as AnyCoder<String>, expiry: .seconds(10))

        // Launching the helper and waiting for it blocks for seconds; keep that off the cooperative pool.
        _ = try await onDedicatedThread { try cleaner.removeExpired() }

        #expect(await onDedicatedThread { helper.waitForExit(timeout: .seconds(60)) }, "helper process did not finish")
        #expect(helper.output.contains("replaced"), "helper output: \(helper.output)")

        try await cleaner.checkForExternalChanges()
        #expect(try await cleaner.get(valueFor: key) == "fresh")
    }
    #endif
}

#if os(macOS)
/// Runs `osascript -l JavaScript` to replace a file inside a coordinated write on the lock file.
private final class CoordinatedReplaceHelper: @unchecked Sendable {
    private static let script = """
        ObjC.import('Foundation');
        function run(argv) {
          var out = $.NSFileHandle.fileHandleWithStandardOutput;
          function say(text) { out.writeData($(text + '\\n').dataUsingEncoding($.NSUTF8StringEncoding)); }
          var lock = $.NSURL.fileURLWithPath(argv[0]);
          var source = $.NSURL.fileURLWithPath(argv[1]);
          var target = $.NSURL.fileURLWithPath(argv[2]);
          var coordinator = $.NSFileCoordinator.alloc.initWithFilePresenter($());
          var error = $();
          say('waiting');
          coordinator.coordinateWritingItemAtURLOptionsErrorByAccessor(lock, 0, error, function(url) {
            $.NSData.dataWithContentsOfURL(source).writeToURLAtomically(target, true);
            say('replaced');
          });
          return '';
        }
        """

    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var buffer = ""
    private let waiting = DispatchSemaphore(value: 0)
    private let replaced = DispatchSemaphore(value: 0)

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    init(lockURL: URL, sourceURL: URL, targetURL: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).js")
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-l", "JavaScript", scriptURL.path(percentEncoded: false),
            lockURL.path(percentEncoded: false),
            sourceURL.path(percentEncoded: false),
            targetURL.path(percentEncoded: false),
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            lock.lock()
            buffer += text
            lock.unlock()
            if text.contains("waiting") {
                waiting.signal()
            }
            if text.contains("replaced") {
                replaced.signal()
            }
        }
    }

    /// Starts the helper and returns once it is about to request the coordinated write.
    ///
    /// Without shared coordination the helper's replacement completes right away, so this also
    /// waits briefly for it to make the race observable; with coordination it cannot complete
    /// while the cleaning depot holds the critical section.
    func startAndWaitUntilCoordinating() {
        do {
            try process.run()
        } catch {
            Issue.record("Failed to launch helper: \(error)")
            return
        }
        if waiting.wait(timeout: .now() + .seconds(30)) != .success {
            Issue.record("Helper did not start")
        }
        _ = replaced.wait(timeout: .now() + .seconds(1))
    }

    func waitForExit(timeout: Duration) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout.components.seconds))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Drain remaining output.
        Thread.sleep(forTimeInterval: 0.1)
        return !process.isRunning
    }
}
#endif
