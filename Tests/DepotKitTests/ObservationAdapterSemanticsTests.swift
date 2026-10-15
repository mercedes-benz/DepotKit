// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if OBSERVATION_ENABLED && canImport(SwiftUI) && canImport(Observation)

import Foundation
import Observation
import SwiftUI
import Testing
import os

@testable import DepotKit
@testable import DepotKitObservation

#if canImport(AppKit)
import AppKit
#endif

/// Write semantics, error exposure, teardown, and repeated construction of the SwiftUI adapters
/// (`@DepotValue` / `@DepotValues`).
///
/// Documented write semantics: a write through the binding is asynchronous; the displayed value
/// is not updated optimistically but only when the depot's observation delivers the stored
/// value. A failed write leaves the displayed value unchanged and exposes the error through
/// `error` until the next successful delivery.
@MainActor
@Suite("Observation adapters: write semantics and lifetime")
struct ObservationAdapterSemanticsTests {
    // MARK: - Helpers

    /// Encodes non-negative integers only; encoding a negative value fails, so writes can be made
    /// to fail on demand while reads keep working.
    struct NonNegativeIntCoder: Coder {
        struct Rejected: Error {}

        func encode(_ value: Int) throws -> Data {
            guard value >= 0 else {
                throw Rejected()
            }
            return Data(String(value).utf8)
        }

        func decode(_ data: Data) throws -> Int {
            guard let value = Int(String(decoding: data, as: UTF8.self)) else {
                throw Rejected()
            }
            return value
        }
    }

    private static func makeDepot(fileBacked: Bool) -> Depot {
        fileBacked ? Depot.temporary() : Depot()
    }

    private static func removeDirectory(of depot: Depot) {
        if let url = depot.configuration.directoryURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Initial delivery

    @Test("the initial value is delivered asynchronously after creation", arguments: [false, true])
    func initialDeliveryIsAsynchronous(fileBacked: Bool) async throws {
        let depot = Self.makeDepot(fileBacked: fileBacked)
        defer { Self.removeDirectory(of: depot) }
        let key = depot.register(keyPath: "items" / "a", coder: .data(Int.self))
        let pattern = depot.register(keyPath: "items" / .wildcard, coder: .data(Int.self))
        try await depot.set(value: 1, for: key)

        let single = DepotValueStorage(depot: depot, key: key, initialValue: true)
        let multi = DepotValuesStorage(depot: depot, key: pattern, initialValues: true)
        #expect(single.value == nil)
        #expect(multi.values.isEmpty)

        #expect(await waitUntilObserved { single.value == 1 && multi.values == [1] })
    }

    // MARK: - Write semantics

    @Test("a write is not displayed until the depot delivers it", arguments: [false, true])
    func writeIsDisplayedAfterDelivery(fileBacked: Bool) async throws {
        let depot = Self.makeDepot(fileBacked: fileBacked)
        defer { Self.removeDirectory(of: depot) }
        let key = depot.register(keyPath: "count", coder: .data(Int.self))
        try await depot.set(value: 1, for: key)

        let storage = DepotValueStorage(depot: depot, key: key, initialValue: true)
        #expect(await waitUntilObserved { storage.value == 1 })

        storage.setValue(2)
        // No optimistic update: the write runs asynchronously and has not been delivered yet.
        #expect(storage.value == 1)

        #expect(await waitUntilObserved { storage.value == 2 })
        #expect(try await depot.get(valueFor: key) == 2)
        #expect(storage.error == nil)
    }

    @Test("a failed write keeps the displayed value and exposes the error until the next delivery")
    func failedWrite() async throws {
        let depot = Depot.temporary()
        defer { Self.removeDirectory(of: depot) }
        let key = depot.register(keyPath: "count", coder: AnyCoder(NonNegativeIntCoder()))
        try await depot.set(value: 1, for: key)

        let storage = DepotValueStorage(depot: depot, key: key, initialValue: true)
        #expect(await waitUntilObserved { storage.value == 1 })

        storage.setValue(-1)
        await storage.waitForPendingWritesForTesting()
        #expect(storage.error != nil)
        #expect(storage.error is NonNegativeIntCoder.Rejected)
        await depot.waitForPendingObservations()
        #expect(storage.value == 1)
        #expect(try await depot.get(valueFor: key) == 1)

        // The error stays exposed while nothing changes …
        try await Task.sleep(for: .milliseconds(50))
        #expect(storage.error != nil)

        // … and is cleared by the next successful delivery, e.g. of a later write.
        storage.setValue(3)
        #expect(await waitUntilObserved { storage.value == 3 && storage.error == nil })

        // A change made elsewhere also clears a write error.
        storage.setValue(-2)
        await storage.waitForPendingWritesForTesting()
        #expect(storage.error != nil)
        try await depot.set(value: 4, for: key)
        #expect(await waitUntilObserved { storage.value == 4 && storage.error == nil })
    }

    @Test("rapid writes across main-actor turns: the last write wins", arguments: [false, true])
    func rapidWritesAcrossTurns(fileBacked: Bool) async throws {
        let depot = Self.makeDepot(fileBacked: fileBacked)
        defer { Self.removeDirectory(of: depot) }
        let key = depot.register(keyPath: "count", coder: .data(Int.self))

        let storage = DepotValueStorage(depot: depot, key: key, initialValue: true)
        let lastValue = 300
        for value in 1...lastValue {
            storage.setValue(value)
            if value.isMultiple(of: 3) {
                try await Task.sleep(for: .microseconds(50))
            } else {
                await Task.yield()
            }
        }

        await storage.waitForPendingWritesForTesting()
        #expect(await waitUntilObserved { storage.value == lastValue })
        await depot.waitForPendingObservations()
        // Give any overtaken earlier write the chance to land (it must not).
        try await Task.sleep(for: .milliseconds(100))
        await depot.waitForPendingObservations()
        #expect(try await depot.get(valueFor: key) == lastValue)
        #expect(storage.value == lastValue)
        #expect(storage.error == nil)
    }

    @Test("a later write is never overtaken by an earlier, slower write")
    func laterWriteIsNotOvertaken() async throws {
        let depot = Depot.temporary()
        defer { Self.removeDirectory(of: depot) }
        let key = depot.register(keyPath: "list", coder: .json([Int].self))

        let storage = DepotValueStorage(depot: depot, key: key, initialValue: false)
        // Encoding the large value takes far longer than the small one, so without ordering the
        // later small write would finish first and then be overwritten by the earlier write.
        storage.setValue(Array(repeating: 1, count: 1_000_000))
        try await Task.sleep(for: .milliseconds(20))
        storage.setValue([2])

        // Writes are chained, so this waits for both writes.
        await storage.waitForPendingWritesForTesting()
        #expect(try await depot.get(valueFor: key) == [2])
        // Give an overtaken earlier write the chance to land (it must not).
        try await Task.sleep(for: .milliseconds(500))
        await depot.waitForPendingObservations()
        #expect(try await depot.get(valueFor: key) == [2])
        #expect(await waitUntilObserved { storage.value == [2] })
    }

    @Test("a write issued right before teardown still reaches the depot")
    func writeBeforeTeardown() async throws {
        let depot = Depot.temporary()
        defer { Self.removeDirectory(of: depot) }
        let key = depot.register(keyPath: "count", coder: .data(Int.self))

        let reference: WeakReference<DepotValueStorage<Int>>
        do {
            let storage = DepotValueStorage(depot: depot, key: key, initialValue: false)
            reference = WeakReference(storage)
            storage.setValue(9)
        }
        #expect(await waitOnMain { reference.isReleased })
        #expect(await waitUntil(timeout: observationTestTimeout) { (try? depot.get(valueFor: key)) == 9 })
    }

    // MARK: - Teardown

    @Test("releasing the storage ends its depot observation", arguments: [false, true])
    func storageTeardownReleasesObservation(fileBacked: Bool) async throws {
        let depot = Self.makeDepot(fileBacked: fileBacked)
        defer { Self.removeDirectory(of: depot) }
        let key = depot.register(keyPath: "items" / "a", coder: .data(Int.self))
        let pattern = depot.register(keyPath: "items" / .wildcard, coder: .data(Int.self))
        try await depot.set(value: 1, for: key)

        let single: WeakReference<DepotValueStorage<Int>>
        let multi: WeakReference<DepotValuesStorage<Int>>
        do {
            let singleStorage = DepotValueStorage(depot: depot, key: key, initialValue: true)
            let multiStorage = DepotValuesStorage(depot: depot, key: pattern, initialValues: true)
            single = WeakReference(singleStorage)
            multi = WeakReference(multiStorage)
            #expect(await waitUntilObserved { singleStorage.value == 1 && multiStorage.values == [1] })
            #expect(depot.core.activeStreamCount == 2)
        }

        #expect(await waitOnMain { single.isReleased && multi.isReleased })
        #expect(await waitOnMain { depot.core.activeStreamCount == 0 })

        try await depot.set(value: 2, for: key)
        await depot.waitForPendingObservations()
        #expect(depot.core.activeStreamCount == 0)
    }
}

// MARK: - Property wrappers hosted in SwiftUI (macOS)

#if canImport(AppKit)

@MainActor
@Suite("Observation adapters: hosted write semantics and repeated construction")
struct ObservationHostedSemanticsTests {
    /// Collects what hosted views observed during `body` evaluations.
    @MainActor
    final class Recorder {
        var singleRendered: [Int?] = []
        var multiRendered: [[Int]] = []
        var binding: Binding<Int?>?
        var singleError: Error?
        var multiError: Error?
        var parentBodies = 0
    }

    @MainActor
    @Observable
    final class Ticker {
        var tick = 0
    }

    struct SingleValueView: View {
        @DepotValue
        var value: Int?
        let recorder: Recorder

        init(_ wrapper: DepotValue<Int>, recorder: Recorder) {
            _value = wrapper
            self.recorder = recorder
        }

        var body: some View {
            recorder.singleRendered.append(value)
            recorder.binding = $value
            recorder.singleError = _value.error
            return Text("\(value ?? -1)")
        }
    }

    struct MultiValueView: View {
        @DepotValues
        var values: [Int]
        let recorder: Recorder

        init(_ wrapper: DepotValues<Int>, recorder: Recorder) {
            _values = wrapper
            self.recorder = recorder
        }

        var body: some View {
            recorder.multiRendered.append(values.sorted())
            recorder.multiError = _values.error
            return Text("\(values.count)")
        }
    }

    /// Re-creates both child views (and therefore new property-wrapper values from key
    /// definitions) on every tick.
    struct ParentView: View {
        let ticker: Ticker
        let depot: Depot
        let definition: KeyDefinition<Int>
        let patternDefinition: PatternKeyDefinition<Int>
        let recorder: Recorder

        var body: some View {
            recorder.parentBodies += 1
            return VStack {
                Text("\(ticker.tick)")
                SingleValueView(DepotValue(definition: definition, depot: depot), recorder: recorder)
                MultiValueView(DepotValues(definition: patternDefinition, depot: depot), recorder: recorder)
            }
        }
    }

    private final class Host {
        let window: NSWindow
        private var view: NSView?

        @MainActor
        init(_ rootView: some View) {
            let view = NSHostingView(rootView: rootView)
            self.view = view
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [],
                backing: .buffered,
                defer: true,
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
        }

        @MainActor
        func pump() {
            view?.layoutSubtreeIfNeeded()
        }

        /// Removes the hosted view hierarchy, releasing the SwiftUI state of its views.
        @MainActor
        func tearDown() {
            window.contentView = nil
            view = nil
        }
    }

    @Test("the binding keeps showing the previous value until the write is delivered")
    func bindingWriteSemantics() async throws {
        let depot = Depot()
        let key = depot.register(keyPath: "count", coder: .data(Int.self))
        try await depot.set(value: 1, for: key)

        let recorder = Recorder()
        let host = Host(SingleValueView(DepotValue(key: key, depot: depot), recorder: recorder))
        defer { host.tearDown() }
        #expect(await waitOnMain(pump: host.pump) { recorder.singleRendered.last == 1 })
        let binding = try #require(recorder.binding)

        binding.wrappedValue = 2
        #expect(binding.wrappedValue == 1)

        #expect(await waitOnMain(pump: host.pump) { recorder.singleRendered.last == 2 })
        #expect(binding.wrappedValue == 2)
        #expect(try await depot.get(valueFor: key) == 2)
        // Before the asynchronous initial delivery the view renders `nil`; afterwards it never
        // falls back to `nil` or skips back to an older value.
        #expect(Array(recorder.singleRendered.drop { $0 == nil }).allSatisfy { $0 == 1 || $0 == 2 })
        #expect(recorder.singleRendered.drop { $0 == nil }.last == 2)
    }

    @Test("observation errors are exposed to the view and cleared by the next successful delivery")
    func errorExposure() async throws {
        let depot = Depot()
        let key = Key.from("late", as: Int.self)
        let pattern = Key.from("items" / .wildcard, as: Int.self)

        let recorder = Recorder()
        let host = Host(
            VStack {
                SingleValueView(DepotValue(key: key, depot: depot), recorder: recorder)
                MultiValueView(DepotValues(key: pattern, depot: depot), recorder: recorder)
            }
        )
        defer { host.tearDown() }
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleError is DepotError && recorder.multiError is DepotError
            }
        )
        #expect(recorder.singleRendered.last == .some(nil))
        #expect(recorder.multiRendered.last == [])

        depot.register(keyPath: "late", coder: .data(Int.self))
        depot.register(keyPath: "items" / .wildcard, coder: .data(Int.self))
        try await depot.set(value: 7, for: key)
        try await depot.set(value: 8, for: Key.from("items" / "a", as: Int.self))
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 7 && recorder.multiRendered.last == [8]
                    && recorder.singleError == nil && recorder.multiError == nil
            }
        )
    }

    @Test("re-creating views from key definitions keeps one observation per view and the stored values")
    func repeatedConstruction() async throws {
        let depot = Depot()
        let definition = KeyDefinition<Int>(path: "settings" / "volume", coder: .data(Int.self))
        let patternDefinition = PatternKeyDefinition<Int>(path: "items" / .wildcard, coder: .data(Int.self))
        _ = depot.register(definition)
        _ = depot.register(patternDefinition)
        let volumeKey = Key.from("settings" / "volume", as: Int.self)
        try await depot.set(value: 3, for: volumeKey)
        try await depot.set(value: 1, for: Key.from("items" / "a", as: Int.self))
        let registeredKeys = depot.keys

        let ticker = Ticker()
        let recorder = Recorder()
        let host = Host(
            ParentView(
                ticker: ticker,
                depot: depot,
                definition: definition,
                patternDefinition: patternDefinition,
                recorder: recorder,
            )
        )
        defer { host.tearDown() }
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 3 && recorder.multiRendered.last == [1]
            }
        )

        let rebuilds = 30
        for tick in 1...rebuilds {
            ticker.tick = tick
            #expect(await waitOnMain(pump: host.pump) { recorder.parentBodies > tick })
        }

        // Discarded wrapper instances end their observations; only the two live views observe.
        #expect(await waitOnMain(pump: host.pump) { depot.core.activeStreamCount == 2 })
        #expect(depot.keys == registeredKeys)
        // Apart from the renders before the asynchronous initial delivery, every render shows the
        // stored values: re-created wrappers never reset the displayed state.
        #expect(recorder.singleRendered.drop { $0 == nil }.allSatisfy { $0 == 3 })
        #expect(recorder.multiRendered.drop { $0.isEmpty }.allSatisfy { $0 == [1] })
        #expect(try await depot.get(valueFor: volumeKey) == 3)

        // The persisted view state is still live after the rebuilds.
        recorder.binding?.wrappedValue = 4
        try await depot.set(value: 2, for: Key.from("items" / "b", as: Int.self))
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 4 && recorder.multiRendered.last == [1, 2]
            }
        )
        #expect(try await depot.get(valueFor: volumeKey) == 4)

        // Removing the views ends every observation (the recorded binding would keep the
        // wrapper's state alive, so drop it as well).
        recorder.binding = nil
        host.tearDown()
        #expect(await waitOnMain { depot.core.activeStreamCount == 0 })
    }

    /// Integer coder whose decoding can be made to fail on demand while encoding keeps working.
    struct ToggledDecodingIntCoder: Coder {
        struct DecodingFailed: Error {}

        let failsDecoding = OSAllocatedUnfairLock(initialState: false)

        func encode(_ value: Int) throws -> Data {
            Data(String(value).utf8)
        }

        func decode(_ data: Data) throws -> Int {
            guard !failsDecoding.withLock({ $0 }), let value = Int(String(decoding: data, as: UTF8.self)) else {
                throw DecodingFailed()
            }
            return value
        }
    }

    @Test("a failed write through the binding keeps the rendered value and exposes the error until a write succeeds")
    func failedBindingWrite() async throws {
        typealias NonNegativeIntCoder = ObservationAdapterSemanticsTests.NonNegativeIntCoder
        // File-backed, because a memory-only depot does not encode values.
        let depot = Depot.temporary()
        defer {
            if let url = depot.configuration.directoryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let key = depot.register(keyPath: "count", coder: AnyCoder(NonNegativeIntCoder()))
        try await depot.set(value: 1, for: key)

        let recorder = Recorder()
        let host = Host(SingleValueView(DepotValue(key: key, depot: depot), recorder: recorder))
        defer { host.tearDown() }
        #expect(await waitOnMain(pump: host.pump) { recorder.singleRendered.last == 1 })
        let binding = try #require(recorder.binding)

        binding.wrappedValue = -1
        #expect(await waitOnMain(pump: host.pump) { recorder.singleError is NonNegativeIntCoder.Rejected })
        #expect(recorder.singleRendered.last == 1)
        #expect(binding.wrappedValue == 1)
        #expect(try await depot.get(valueFor: key) == 1)

        binding.wrappedValue = 3
        #expect(
            await waitOnMain(pump: host.pump) { recorder.singleRendered.last == 3 && recorder.singleError == nil }
        )
        #expect(try await depot.get(valueFor: key) == 3)
        #expect(recorder.singleRendered.drop { $0 == nil }.allSatisfy { $0 == 1 || $0 == 3 })
    }

    @Test("decode errors keep the last rendered values and are cleared when reading succeeds again")
    func decodeErrorsKeepLastValues() async throws {
        let depot = Depot.temporary()
        defer {
            if let url = depot.configuration.directoryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let coder = ToggledDecodingIntCoder()
        let key = depot.register(keyPath: "count", coder: AnyCoder(coder))
        let pattern = depot.register(keyPath: "items" / .wildcard, coder: AnyCoder(coder))
        let item = Key.from("items" / "a", as: Int.self)
        try await depot.set(value: 1, for: key)
        try await depot.set(value: 10, for: item)

        let recorder = Recorder()
        let host = Host(
            VStack {
                SingleValueView(DepotValue(key: key, depot: depot), recorder: recorder)
                MultiValueView(DepotValues(key: pattern, depot: depot), recorder: recorder)
            }
        )
        defer { host.tearDown() }
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 1 && recorder.multiRendered.last == [10]
            }
        )

        // Transactions notify observers to re-read the committed values, so both views decode.
        coder.failsDecoding.withLock { $0 = true }
        try await depot.transaction { transaction in
            try transaction.set(value: 2, for: key)
            try transaction.set(value: 20, for: item)
        }
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleError is ToggledDecodingIntCoder.DecodingFailed
                    && recorder.multiError is ToggledDecodingIntCoder.DecodingFailed
            }
        )
        #expect(recorder.singleRendered.last == 1)
        #expect(recorder.multiRendered.last == [10])

        coder.failsDecoding.withLock { $0 = false }
        try await depot.transaction { transaction in
            try transaction.set(value: 3, for: key)
            try transaction.set(value: 30, for: item)
        }
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 3 && recorder.multiRendered.last == [30]
                    && recorder.singleError == nil && recorder.multiError == nil
            }
        )
        #expect(recorder.singleRendered.drop { $0 == nil }.allSatisfy { [1, 3].contains($0) })
        #expect(recorder.multiRendered.drop { $0.isEmpty }.allSatisfy { $0 == [10] || $0 == [30] })
    }

    @Test("removing the hosted views releases the depot", arguments: [false, true])
    func teardownReleasesDepot(fileBacked: Bool) async throws {
        var depot: Depot? = fileBacked ? Depot.temporary() : Depot()
        let directory = depot?.configuration.directoryURL
        defer {
            if let directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let weakDepot = WeakReference(depot)
        let recorder = Recorder()
        let host: Host
        do {
            let depot = try #require(depot)
            let definition = KeyDefinition<Int>(path: "count", coder: .data(Int.self))
            let patternDefinition = PatternKeyDefinition<Int>(path: "items" / .wildcard, coder: .data(Int.self))
            host = Host(
                VStack {
                    SingleValueView(DepotValue(definition: definition, depot: depot), recorder: recorder)
                    MultiValueView(DepotValues(definition: patternDefinition, depot: depot), recorder: recorder)
                }
            )
            try await depot.set(value: 1, for: Key.from("items" / "a", as: Int.self))
            #expect(await waitOnMain(pump: host.pump) { recorder.multiRendered.last == [1] })
            recorder.binding?.wrappedValue = 2
            #expect(await waitOnMain(pump: host.pump) { recorder.singleRendered.last == 2 })
            #expect(try await depot.get(valueFor: Key.from("count", as: Int.self)) == 2)
        }

        // The hosted wrappers keep the depot alive while they are installed …
        depot = nil
        await Task.yield()
        #expect(!weakDepot.isReleased)

        // … and release it with the view hierarchy.
        recorder.binding = nil
        host.tearDown()
        #expect(await waitOnMain { weakDepot.isReleased })
    }
}

#endif

#endif
