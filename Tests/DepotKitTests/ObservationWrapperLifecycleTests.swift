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

/// Lifecycle of the SwiftUI adapters (`@DepotValue` / `@DepotValues`): creating a wrapper has no
/// side effects; registration and observation start in `update()` (before the first `body`
/// evaluation) and restart only when the key (path) or depot changes.
@MainActor
@Suite("Observation adapters: wrapper lifecycle")
struct ObservationWrapperLifecycleTests {
    /// Counts decodes so tests can tell whether a wrapper read from the depot.
    struct CountingIntCoder: Coder {
        let decodes: OSAllocatedUnfairLock<Int>

        func encode(_ value: Int) throws -> Data {
            Data(String(value).utf8)
        }

        func decode(_ data: Data) throws -> Int {
            decodes.withLock { $0 += 1 }
            return Int(String(decoding: data, as: UTF8.self)) ?? -1
        }
    }

    @Test("constructing wrappers without installing them registers nothing and starts no observation")
    func constructionHasNoSideEffects() async throws {
        let depot = Depot.temporary()
        defer {
            if let url = depot.configuration.directoryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let decodes = OSAllocatedUnfairLock(initialState: 0)
        let coder = AnyCoder(CountingIntCoder(decodes: decodes))
        let key = depot.register(keyPath: "registered" / "value", coder: coder)
        let pattern = depot.register(keyPath: "registered" / .wildcard, coder: coder)
        try await depot.set(value: 1, for: key)
        let registeredKeys = depot.keys
        let definition = KeyDefinition<Int>(path: "defined" / "value", coder: coder)
        let patternDefinition = PatternKeyDefinition<Int>(path: "defined" / .wildcard, coder: coder)

        // Keep the wrappers alive so that any work their construction started could complete.
        var singles: [DepotValue<Int>] = []
        var multis: [DepotValues<Int>] = []
        for index in 0..<50 {
            let initial = index.isMultiple(of: 2)
            singles.append(DepotValue(key: key, depot: depot, initialValue: initial))
            singles.append(DepotValue(definition: definition, depot: depot, initialValue: initial))
            multis.append(DepotValues(key: pattern, depot: depot, initialValues: initial))
            multis.append(DepotValues(definition: patternDefinition, depot: depot, initialValues: initial))
        }

        try await Task.sleep(for: .milliseconds(200))
        await depot.waitForPendingObservations()

        #expect(depot.keys == registeredKeys)
        #expect(depot.core.activeStreamCount == 0)
        #expect(decodes.withLock { $0 } == 0)
        #expect(singles.count == 100 && multis.count == 100)
    }
}

// MARK: - Property wrappers hosted in SwiftUI (macOS)

#if canImport(AppKit)

@MainActor
@Suite("Observation adapters: hosted wrapper lifecycle")
struct ObservationHostedLifecycleTests {
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

    /// Drives the parent views: `tick` forces a re-render, `second` selects the second key or depot.
    @MainActor
    @Observable
    final class Model {
        var tick = 0
        var second = false
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

    /// Re-creates both child views from key definitions on every tick.
    struct DefinitionParentView: View {
        let model: Model
        let depot: Depot
        let definition: KeyDefinition<Int>
        let patternDefinition: PatternKeyDefinition<Int>
        let recorder: Recorder

        var body: some View {
            recorder.parentBodies += 1
            return VStack {
                Text("\(model.tick)")
                SingleValueView(DepotValue(definition: definition, depot: depot), recorder: recorder)
                MultiValueView(DepotValues(definition: patternDefinition, depot: depot), recorder: recorder)
            }
        }
    }

    /// Passes the first or second key to the same child views (same view identity).
    struct KeySwitchingParentView: View {
        let model: Model
        let depot: Depot
        let keys: (TypedDistinctKey<Int>, TypedDistinctKey<Int>)
        let patterns: (TypedKey<Int>, TypedKey<Int>)
        let recorder: Recorder

        var body: some View {
            recorder.parentBodies += 1
            return VStack {
                Text("\(model.tick)")
                SingleValueView(
                    DepotValue(key: model.second ? keys.1 : keys.0, depot: depot),
                    recorder: recorder,
                )
                MultiValueView(
                    DepotValues(key: model.second ? patterns.1 : patterns.0, depot: depot),
                    recorder: recorder,
                )
            }
        }
    }

    /// Passes the first or second definition to the same child views (same view identity).
    struct DefinitionSwitchingParentView: View {
        let model: Model
        let depot: Depot
        let definitions: (KeyDefinition<Int>, KeyDefinition<Int>)
        let patternDefinitions: (PatternKeyDefinition<Int>, PatternKeyDefinition<Int>)
        let recorder: Recorder

        var body: some View {
            recorder.parentBodies += 1
            return VStack {
                SingleValueView(
                    DepotValue(definition: model.second ? definitions.1 : definitions.0, depot: depot),
                    recorder: recorder,
                )
                MultiValueView(
                    DepotValues(
                        definition: model.second ? patternDefinitions.1 : patternDefinitions.0,
                        depot: depot,
                    ),
                    recorder: recorder,
                )
            }
        }
    }

    /// Passes the first or second depot to the same child views (same view identity).
    struct DepotSwitchingParentView: View {
        let model: Model
        let depots: (Depot, Depot)
        let key: TypedDistinctKey<Int>
        let pattern: TypedKey<Int>
        let recorder: Recorder

        var body: some View {
            recorder.parentBodies += 1
            let depot = model.second ? depots.1 : depots.0
            return VStack {
                SingleValueView(DepotValue(key: key, depot: depot), recorder: recorder)
                MultiValueView(DepotValues(key: pattern, depot: depot), recorder: recorder)
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

    @Test("re-rendering the parent keeps one observation per wrapper and does not register again")
    func reRenderDoesNotReRegister() async throws {
        let depot = Depot()
        let definition = KeyDefinition<Int>(path: "settings" / "volume", coder: .data(Int.self))
        let patternDefinition = PatternKeyDefinition<Int>(path: "items" / .wildcard, coder: .data(Int.self))
        let volumeKey = Key.from("settings" / "volume", as: Int.self)
        let itemKey = Key.from("items" / "a", as: Int.self)

        let model = Model()
        let recorder = Recorder()
        let host = Host(
            DefinitionParentView(
                model: model,
                depot: depot,
                definition: definition,
                patternDefinition: patternDefinition,
                recorder: recorder,
            )
        )
        defer { host.tearDown() }

        // The definitions are registered when the views are first updated, before their first body.
        #expect(depot.keys == [definition.key.key, patternDefinition.key])
        #expect(await waitOnMain(pump: host.pump) { depot.core.activeStreamCount == 2 })
        try await depot.set(value: 3, for: volumeKey)
        try await depot.set(value: 1, for: itemKey)
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 3 && recorder.multiRendered.last == [1]
            }
        )

        // A registration made after the views started (here: with an expiry) must survive re-renders.
        let expiry = Duration.seconds(3600)
        depot.register(keyPath: "settings" / "volume", coder: .data(Int.self), expiry: expiry)
        depot.register(keyPath: "items" / .wildcard, coder: .data(Int.self), expiry: expiry)

        let rebuilds = 30
        for tick in 1...rebuilds {
            model.tick = tick
            #expect(await waitOnMain(pump: host.pump) { recorder.parentBodies > tick })
            #expect(depot.core.activeStreamCount == 2)
        }

        #expect(recorder.parentBodies > rebuilds)
        #expect(depot.core.expiry(for: volumeKey) == expiry)
        #expect(depot.core.expiry(for: itemKey) == expiry)
        #expect(recorder.singleRendered.drop { $0 == nil }.allSatisfy { $0 == 3 })
        #expect(recorder.multiRendered.drop { $0.isEmpty }.allSatisfy { $0 == [1] })

        // The installed observation is still live.
        recorder.binding?.wrappedValue = 4
        try await depot.set(value: 2, for: Key.from("items" / "b", as: Int.self))
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 4 && recorder.multiRendered.last == [1, 2]
            }
        )
        #expect(depot.core.activeStreamCount == 2)

        recorder.binding = nil
        host.tearDown()
        #expect(await waitOnMain { depot.core.activeStreamCount == 0 })
    }

    @Test("passing a different key restarts the observation; switching back works", arguments: [false, true])
    func keyChangeRestartsObservation(fileBacked: Bool) async throws {
        let depot = fileBacked ? Depot.temporary() : Depot()
        defer {
            if let url = depot.configuration.directoryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let keyA = depot.register(keyPath: "a" / "value", coder: .data(Int.self))
        let keyB = depot.register(keyPath: "b" / "value", coder: .data(Int.self))
        let patternA = depot.register(keyPath: "listA" / .wildcard, coder: .data(Int.self))
        let patternB = depot.register(keyPath: "listB" / .wildcard, coder: .data(Int.self))
        try await depot.set(value: 1, for: keyA)
        try await depot.set(value: 2, for: keyB)
        try await depot.set(value: 10, for: Key.from("listA" / "x", as: Int.self))
        try await depot.set(value: 20, for: Key.from("listB" / "x", as: Int.self))

        let model = Model()
        let recorder = Recorder()
        let host = Host(
            KeySwitchingParentView(
                model: model,
                depot: depot,
                keys: (keyA, keyB),
                patterns: (patternA, patternB),
                recorder: recorder,
            )
        )
        defer { host.tearDown() }
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 1 && recorder.multiRendered.last == [10]
            }
        )

        // Switch to the second keys.
        var singleStart = recorder.singleRendered.count
        var multiStart = recorder.multiRendered.count
        model.second = true
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 2 && recorder.multiRendered.last == [20]
            }
        )
        // After the switch the views never show the old key's values again (only the reset
        // state before the new key's values arrive).
        #expect(recorder.singleRendered[singleStart...].allSatisfy { $0 == nil || $0 == 2 })
        #expect(recorder.multiRendered[multiStart...].allSatisfy { $0.isEmpty || $0 == [20] })
        #expect(await waitOnMain(pump: host.pump) { depot.core.activeStreamCount == 2 })

        // The binding and further changes follow the new key; the old key is no longer observed.
        recorder.binding?.wrappedValue = 5
        #expect(await waitOnMain(pump: host.pump) { recorder.singleRendered.last == 5 })
        #expect(try await depot.get(valueFor: keyB) == 5)
        #expect(try await depot.get(valueFor: keyA) == 1)
        try await depot.set(value: 100, for: keyA)
        try await depot.set(value: 21, for: Key.from("listB" / "y", as: Int.self))
        #expect(await waitOnMain(pump: host.pump) { recorder.multiRendered.last == [20, 21] })
        await depot.waitForPendingObservations()
        #expect(recorder.singleRendered.last == 5)

        // Switch back to the first keys.
        singleStart = recorder.singleRendered.count
        multiStart = recorder.multiRendered.count
        model.second = false
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 100 && recorder.multiRendered.last == [10]
            }
        )
        #expect(recorder.singleRendered[singleStart...].allSatisfy { $0 == nil || $0 == 100 })
        #expect(recorder.multiRendered[multiStart...].allSatisfy { $0.isEmpty || $0 == [10] })
        #expect(await waitOnMain(pump: host.pump) { depot.core.activeStreamCount == 2 })
        #expect(recorder.singleError == nil && recorder.multiError == nil)

        recorder.binding = nil
        host.tearDown()
        #expect(await waitOnMain { depot.core.activeStreamCount == 0 })
    }

    @Test("passing a definition with a different path registers it and restarts the observation")
    func definitionChangeRegistersAndRestarts() async throws {
        let depot = Depot()
        let definitions = (
            KeyDefinition<Int>(path: "a" / "value", coder: .data(Int.self)),
            KeyDefinition<Int>(path: "b" / "value", coder: .data(Int.self)),
        )
        let patternDefinitions = (
            PatternKeyDefinition<Int>(path: "listA" / .wildcard, coder: .data(Int.self)),
            PatternKeyDefinition<Int>(path: "listB" / .wildcard, coder: .data(Int.self)),
        )

        let model = Model()
        let recorder = Recorder()
        let host = Host(
            DefinitionSwitchingParentView(
                model: model,
                depot: depot,
                definitions: definitions,
                patternDefinitions: patternDefinitions,
                recorder: recorder,
            )
        )
        defer { host.tearDown() }
        #expect(depot.keys == [definitions.0.key.key, patternDefinitions.0.key])
        try await depot.set(value: 1, for: Key.from("a" / "value", as: Int.self))
        try await depot.set(value: 10, for: Key.from("listA" / "x", as: Int.self))
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 1 && recorder.multiRendered.last == [10]
            }
        )

        // The second definitions are registered when the views switch to them.
        model.second = true
        #expect(await waitOnMain(pump: host.pump) { depot.keys.count == 4 })
        #expect(depot.keys.isSuperset(of: [definitions.1.key.key, patternDefinitions.1.key]))
        try await depot.set(value: 2, for: Key.from("b" / "value", as: Int.self))
        try await depot.set(value: 20, for: Key.from("listB" / "x", as: Int.self))
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 2 && recorder.multiRendered.last == [20]
            }
        )
        #expect(await waitOnMain(pump: host.pump) { depot.core.activeStreamCount == 2 })

        model.second = false
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 1 && recorder.multiRendered.last == [10]
            }
        )
        #expect(await waitOnMain(pump: host.pump) { depot.core.activeStreamCount == 2 })
        #expect(recorder.singleError == nil && recorder.multiError == nil)
    }

    @Test("passing a different depot restarts the observation in that depot")
    func depotChangeRestartsObservation() async throws {
        let depots = (Depot(), Depot())
        let key = Key.from("value", as: Int.self)
        let pattern = Key.from("list" / .wildcard, as: Int.self)
        for (depot, offset) in [(depots.0, 0), (depots.1, 1)] {
            depot.register(keyPath: "value", coder: .data(Int.self))
            depot.register(keyPath: "list" / .wildcard, coder: .data(Int.self))
            try await depot.set(value: 1 + offset, for: key)
            try await depot.set(value: 10 + offset, for: Key.from("list" / "x", as: Int.self))
        }

        let model = Model()
        let recorder = Recorder()
        let host = Host(
            DepotSwitchingParentView(model: model, depots: depots, key: key, pattern: pattern, recorder: recorder)
        )
        defer { host.tearDown() }
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 1 && recorder.multiRendered.last == [10]
            }
        )

        model.second = true
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 2 && recorder.multiRendered.last == [11]
            }
        )
        #expect(await waitOnMain(pump: host.pump) { depots.0.core.activeStreamCount == 0 })
        #expect(await waitOnMain(pump: host.pump) { depots.1.core.activeStreamCount == 2 })

        recorder.binding?.wrappedValue = 7
        #expect(await waitOnMain(pump: host.pump) { recorder.singleRendered.last == 7 })
        #expect(try await depots.1.get(valueFor: key) == 7)
        #expect(try await depots.0.get(valueFor: key) == 1)

        model.second = false
        #expect(
            await waitOnMain(pump: host.pump) {
                recorder.singleRendered.last == 1 && recorder.multiRendered.last == [10]
            }
        )
        #expect(await waitOnMain(pump: host.pump) { depots.1.core.activeStreamCount == 0 })
        #expect(await waitOnMain(pump: host.pump) { depots.0.core.activeStreamCount == 2 })
    }
}

#endif

#endif
