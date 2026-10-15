// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if COMBINE_ENABLED && canImport(Combine)

import Combine
import DepotKit
import Foundation
import Testing

@testable import DepotKitCombine

/// The `isInitial` flag passed to the available-values error handler must be gated by
/// `initialValues`, consistently with the other error-handling publishers.
///
/// These tests use *top-level* observation failures (the whole available-values read fails),
/// not per-key decode failures, which are reported inside a successful result.
@Suite("Combine available-values error classification")
struct CombineAvailableValuesErrorTests {
    /// A depot in which every available-values read of `pattern` fails at the top level while
    /// writes to `item` still succeed and notify observers of `pattern`.
    ///
    /// - Memory-only: `items/a` is registered as a distinct key but the observed pattern
    ///   `items/*` is not, so the read throws `DepotError.unregisteredKey`.
    /// - File-backed: `items/*` is registered, but the `items` directory is made unlistable
    ///   (write/execute only), so enumerating it throws while writing `items/a` still works.
    private struct FailingFixture {
        let depot: Depot
        let item: TypedDistinctKey<String>
        let pattern: TypedKey<String>
        let restore: @Sendable () -> Void
    }

    private static func makeFailingFixture(fileBacked: Bool) async throws -> FailingFixture {
        let item = Key.from("items" / "a", as: String.self)
        guard fileBacked else {
            let depot = Depot()
            _ = depot.register(key: Key.from("items" / "a"), coder: .data(String.self))
            return FailingFixture(
                depot: depot,
                item: item,
                pattern: Key.from("items" / .wildcard, as: String.self),
                restore: {},
            )
        }

        let depot = Depot.temporary()
        let pattern = depot.register(key: Key.from("items" / .wildcard), coder: .data(String.self))
        try await depot.set(value: "seed", for: item)

        let depotURL = try #require(depot.configuration.directoryURL)
        let directories = try FileManager.default
            .contentsOfDirectory(
                at: depotURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
            )
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let itemsDirectory = try #require(directories.count == 1 ? directories.first : nil)
        let path = itemsDirectory.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: path)
        let restore: @Sendable () -> Void = {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            try? FileManager.default.removeItem(at: depotURL)
        }

        // Sanity check: the fixture really produces a top-level failure.
        do {
            _ = try await depot.get(availableValuesFor: pattern)
            restore()
            Issue.record("Expected a top-level available-values failure")
        } catch {}

        return FailingFixture(depot: depot, item: item, pattern: pattern, restore: restore)
    }

    @Test(
        "initialValues: false classifies the first top-level failure as non-initial",
        arguments: [false, true],
    )
    func initialDisabledFirstFailureIsNotInitial(fileBacked: Bool) async throws {
        let fixture = try await Self.makeFailingFixture(fileBacked: fileBacked)
        defer { fixture.restore() }
        let recorder = IsInitialRecorder()
        let subscriber = DemandTestSubscriber<[String], Error>(initialDemand: .unlimited)

        fixture.depot.published(availableValuesFor: fixture.pattern, initialValues: false) { _, isInitial in
            recorder.record(isInitial)
            return .skip
        }
        .subscribe(subscriber)

        try await fixture.depot.set(value: "first", for: fixture.item)
        await fixture.depot.waitForPendingObservations()
        #expect(await recorder.waitForRecords(count: 1))

        try await fixture.depot.set(value: "second", for: fixture.item)
        await fixture.depot.waitForPendingObservations()
        #expect(await recorder.waitForRecords(count: 2))

        #expect(recorder.recorded == [false, false])
        #expect(subscriber.values.isEmpty)
        subscriber.cancel()
    }

    @Test(
        "initialValues: true classifies only the initial top-level failure as initial",
        arguments: [false, true],
    )
    func initialEnabledFirstFailureIsInitial(fileBacked: Bool) async throws {
        let fixture = try await Self.makeFailingFixture(fileBacked: fileBacked)
        defer { fixture.restore() }
        let recorder = IsInitialRecorder()
        let subscriber = DemandTestSubscriber<[String], Error>(initialDemand: .unlimited)

        fixture.depot.published(availableValuesFor: fixture.pattern, initialValues: true) { _, isInitial in
            recorder.record(isInitial)
            return .replaceWith(isInitial ? ["initial"] : ["update"])
        }
        .subscribe(subscriber)

        #expect(await recorder.waitForRecords(count: 1))
        await fixture.depot.waitForPendingObservations()

        try await fixture.depot.set(value: "first", for: fixture.item)
        await fixture.depot.waitForPendingObservations()
        #expect(await recorder.waitForRecords(count: 2))

        #expect(recorder.recorded == [true, false])
        #expect(await subscriber.waitForValues(count: 2))
        #expect(subscriber.values == [["initial"], ["update"]])
        subscriber.cancel()
    }

    // MARK: - Consistency across all error-handling publishers (deterministic)

    @Test(
        "First-event failure is initial only when initial delivery is enabled",
        arguments: CombineVariant.errorHandling,
        [false, true],
    )
    func firstEventFailure(variant: CombineVariant, initialValues: Bool) {
        let recorder = IsInitialRecorder()
        let harness = variant.makeHarness(
            .detached(initialValues: initialValues),
            initialDemand: .unlimited,
            isInitialRecorder: recorder,
        )

        harness.processFailure()
        harness.processFailure()

        #expect(recorder.recorded == [initialValues, false])
    }

    @Test(
        "A failure after a successful first event is never initial",
        arguments: CombineVariant.errorHandling,
        [false, true],
    )
    func failureAfterFirstEventSuccess(variant: CombineVariant, initialValues: Bool) {
        let recorder = IsInitialRecorder()
        let harness = variant.makeHarness(
            .detached(initialValues: initialValues),
            initialDemand: .unlimited,
            isInitialRecorder: recorder,
        )

        harness.process(1)
        harness.processFailure()

        #expect(recorder.recorded == [false])
        #expect(harness.values() == [1])
    }
}

#endif
