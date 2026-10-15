// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if os(macOS)

import Foundation
import Testing
import os

@testable import DepotKit

/// Cross-process change signaling with a real second process.
///
/// A helper process (a JavaScript-for-Automation script run by `osascript`, so no extra build
/// product is needed) changes a value file of a multi-process depot directory the way another
/// DepotKit process does: inside a coordinated write on the shared lock file, followed by touching
/// the lock file. The in-process depot must pick the change up through its registered
/// `NSFilePresenter` — invalidating its memory cache and notifying observers — without a manual
/// `checkForExternalChanges()` call.
///
/// All waits are upper bounds; delivery by the operating system is asynchronous and eventual.
@Suite(
    "Cross-process change signaling with a helper process",
    .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript")),
)
struct CrossProcessChangeSignalingTests {
    private static let deliveryTimeout: Duration = .seconds(60)

    /// A depot directory shared with the helper, plus a second directory holding the bytes of
    /// replacement values (written by a regular depot so they carry a valid header).
    private struct Fixture {
        let url: URL
        let sourceURL: URL
        let depot: Depot
        let source: Depot
        let key: TypedDistinctKey<String>
        let sourceKey: TypedDistinctKey<String>

        init(memoryCache: DepotConfiguration.MemoryCacheCapacity = .default) throws {
            url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
            sourceURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
            depot = Depot(
                configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: memoryCache),
                overrides: .init(initSweepDelay: .seconds(3600)),
            )
            source = Depot(
                configuration: .init(directoryURL: sourceURL),
                overrides: .init(initSweepDelay: .seconds(3600)),
            )
            key = depot.register(keyPath: "token", coder: .json() as AnyCoder<String>)
            sourceKey = source.register(keyPath: "token", coder: .json() as AnyCoder<String>)
        }

        var lockURL: URL {
            url.appending(component: "\(Depot.HiddenKeyPrefix)LOCK")
        }

        /// Lets the helper process replace the value with `value`.
        func replaceExternally(with value: String) async throws {
            try await source.set(value: value, for: sourceKey)
            try await ExternalWriter.run(
                .replace(source: try source.fileURL(for: sourceKey)),
                lockURL: lockURL,
                targetURL: try depot.fileURL(for: key),
            )
        }

        /// Lets the helper process remove the value.
        func removeExternally() async throws {
            try await ExternalWriter.run(.remove, lockURL: lockURL, targetURL: try depot.fileURL(for: key))
        }

        func tearDown() {
            try? depot.removeFilePresenter()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: sourceURL)
        }
    }

    /// Collects every delivery of a value stream.
    private static func observe(_ fixture: Fixture) -> (DeliveryLog<String?>, Task<Void, Never>) {
        let log = DeliveryLog<String?>()
        let stream = fixture.depot.values(for: fixture.key)
        let task = Task {
            for await result in stream {
                log.append(DeliveryLog.value(of: result))
            }
        }
        return (log, task)
    }

    @Test("automatic checks invalidate the cache and notify observers of another process's writes and removals")
    func automaticChecksPickUpExternalChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try await fixture.depot.set(value: "old", for: fixture.key)
        #expect(try await fixture.depot.get(valueFor: fixture.key) == "old")

        try fixture.depot.automaticallyCheckForExternalChanges(debounceInterval: 0.05)
        let (log, task) = Self.observe(fixture)
        defer { task.cancel() }
        #expect(await waitUntil(timeout: Self.deliveryTimeout) { log.last == "old" })

        try await fixture.replaceExternally(with: "new")
        #expect(
            await waitUntil(timeout: Self.deliveryTimeout) { log.last == "new" },
            "observer was not notified of the external write (deliveries: \(log.all))",
        )
        // The cached "old" value was invalidated without a manual check.
        #expect(try await fixture.depot.get(valueFor: fixture.key) == "new")

        try await fixture.removeExternally()
        #expect(
            await waitUntil(timeout: Self.deliveryTimeout) { log.last == .some(nil) },
            "observer was not notified of the external removal (deliveries: \(log.all))",
        )
        #expect(try await fixture.depot.get(valueFor: fixture.key) == nil)
        #expect(!log.all.contains("<error>"))
    }

    @Test("without a file presenter, external changes are only picked up by an explicit check")
    func explicitCheckWithoutPresenter() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try await fixture.depot.set(value: "old", for: fixture.key)
        #expect(try await fixture.depot.get(valueFor: fixture.key) == "old")

        try await fixture.replaceExternally(with: "new")
        // The helper has exited; nothing invalidated the cached value.
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await fixture.depot.get(valueFor: fixture.key) == "old")

        try await fixture.depot.checkForExternalChanges()
        #expect(try await fixture.depot.get(valueFor: fixture.key) == "new")
    }

    @Test("removing the file presenter stops automatic checks; adding it again resumes them")
    func presenterRemovalAndReAddition() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try await fixture.depot.set(value: "old", for: fixture.key)
        try fixture.depot.automaticallyCheckForExternalChanges(debounceInterval: 0.05)
        #expect(try await fixture.depot.get(valueFor: fixture.key) == "old")

        // What an iOS host app does when it enters the background.
        try await fixture.depot.removeFilePresenter()
        try await fixture.replaceExternally(with: "while removed")
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await fixture.depot.get(valueFor: fixture.key) == "old")

        // … and when it returns to the foreground: changes signaled from now on are picked up,
        // together with the change made while the presenter was removed.
        try await fixture.depot.addFilePresenter()
        let (log, task) = Self.observe(fixture)
        defer { task.cancel() }
        #expect(await waitUntil(timeout: Self.deliveryTimeout) { log.count == 1 })

        try await fixture.replaceExternally(with: "after re-adding")
        #expect(
            await waitUntil(timeout: Self.deliveryTimeout) { log.last == "after re-adding" },
            "observer was not notified after re-adding the presenter (deliveries: \(log.all))",
        )
        #expect(try await fixture.depot.get(valueFor: fixture.key) == "after re-adding")
    }
}

/// Runs `osascript -l JavaScript` to change a value file inside a coordinated write on the
/// shared lock file and to touch the lock file afterwards, mirroring a DepotKit writer in another
/// process.
private enum ExternalWriter {
    enum Operation {
        case replace(source: URL)
        case remove
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let script = """
        ObjC.import('Foundation');
        function run(argv) {
          var mode = argv[0];
          var lock = $.NSURL.fileURLWithPath(argv[1]);
          var target = $.NSURL.fileURLWithPath(argv[2]);
          var fm = $.NSFileManager.defaultManager;
          var coordinator = $.NSFileCoordinator.alloc.initWithFilePresenter($());
          var error = $();
          var result = 'not run';
          coordinator.coordinateWritingItemAtURLOptionsErrorByAccessor(lock, 0, error, function(url) {
            var ok;
            if (mode === 'replace') {
              var data = $.NSData.dataWithContentsOfURL($.NSURL.fileURLWithPath(argv[3]));
              ok = data.writeToURLAtomically(target, true);
            } else {
              ok = fm.removeItemAtURLError(target, $());
            }
            var attributes = $.NSDictionary.dictionaryWithObjectForKey($.NSDate.date, $.NSFileModificationDate);
            fm.setAttributesOfItemAtPathError(attributes, url.path, $());
            result = ok ? 'done' : 'failed';
          });
          return result;
        }
        """

    /// Runs the helper to completion on a dedicated thread (launching and waiting block).
    static func run(_ operation: Operation, lockURL: URL, targetURL: URL) async throws {
        let scriptURL = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).js")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        var arguments = ["-l", "JavaScript", scriptURL.path(percentEncoded: false)]
        switch operation {
        case let .replace(source):
            arguments += ["replace", lockURL.path(percentEncoded: false), targetURL.path(percentEncoded: false)]
            arguments.append(source.path(percentEncoded: false))
        case .remove:
            arguments += ["remove", lockURL.path(percentEncoded: false), targetURL.path(percentEncoded: false)]
        }
        let launchArguments = arguments

        let output = try await onDedicatedThread { () throws -> String in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = launchArguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()

            let deadline = Date().addingTimeInterval(60)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard !process.isRunning else {
                process.terminate()
                throw Failure(description: "helper process did not finish")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard output == "done" else {
            throw Failure(description: "helper process reported '\(output)'")
        }
    }
}

#endif
