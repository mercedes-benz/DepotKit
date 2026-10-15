// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if OBSERVATION_ENABLED && canImport(SwiftUI) && canImport(Observation)

import DepotKit
import Foundation
import SwiftUI
import Testing

@testable import DepotKitObservation

#if canImport(AppKit)
import AppKit
#endif

private func makeDepot(fileBacked: Bool) -> Depot {
    fileBacked ? Depot.temporary() : Depot()
}

private func removeDirectory(of depot: Depot) {
    if let url = depot.configuration.directoryURL {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Storage (platform independent)

@MainActor
@Suite("Observation adapters: storage")
struct ObservationStorageTests {
    @Test("DepotValueStorage delivers the initial value, updates and removals", arguments: [false, true])
    func singleValuePropagation(fileBacked: Bool) async throws {
        let depot = makeDepot(fileBacked: fileBacked)
        defer { removeDirectory(of: depot) }
        _ = depot.register(key: Key.from("count"), coder: .data(Int.self))
        let key = Key.from("count", as: Int.self)
        try await depot.set(value: 1, for: key)

        let storage = DepotValueStorage(depot: depot, key: key, initialValue: true)
        #expect(await waitUntilObserved { storage.value == 1 })

        try await depot.set(value: 2, for: key)
        #expect(await waitUntilObserved { storage.value == 2 })

        try await depot.remove(valueFor: key)
        #expect(await waitUntilObserved { storage.value == nil })
        #expect(storage.error == nil)
    }

    @Test("DepotValueStorage with initialValue: false waits for the first change")
    func singleValueWithoutInitialValue() async throws {
        let depot = Depot()
        _ = depot.register(key: Key.from("count"), coder: .data(Int.self))
        let key = Key.from("count", as: Int.self)
        try await depot.set(value: 1, for: key)

        let storage = DepotValueStorage(depot: depot, key: key, initialValue: false)
        await depot.waitForPendingObservations()
        #expect(storage.value == nil)

        try await depot.set(value: 2, for: key)
        #expect(await waitUntilObserved { storage.value == 2 })
    }

    @Test("DepotValueStorage.setValue writes through to the depot", arguments: [false, true])
    func singleValueWriteThrough(fileBacked: Bool) async throws {
        let depot = makeDepot(fileBacked: fileBacked)
        defer { removeDirectory(of: depot) }
        _ = depot.register(key: Key.from("name"), coder: .data(String.self))
        let key = Key.from("name", as: String.self)

        let storage = DepotValueStorage(depot: depot, key: key, initialValue: true)
        storage.setValue("alice")
        await storage.waitForPendingWritesForTesting()
        #expect(try await depot.get(valueFor: key) == "alice")
        #expect(await waitUntilObserved { storage.value == "alice" })

        storage.setValue(nil)
        await storage.waitForPendingWritesForTesting()
        #expect(try await depot.get(valueFor: key) == nil)
        #expect(await waitUntilObserved { storage.value == nil })
        #expect(storage.error == nil)
    }

    @Test("DepotValueStorage: the last of several rapid writes wins")
    func singleValueRapidWrites() async throws {
        let depot = Depot.temporary()
        defer { removeDirectory(of: depot) }
        _ = depot.register(key: Key.from("count"), coder: .data(Int.self))
        let key = Key.from("count", as: Int.self)

        let storage = DepotValueStorage(depot: depot, key: key, initialValue: true)
        for value in 1...20 {
            storage.setValue(value)
        }
        await storage.waitForPendingWritesForTesting()
        #expect(await waitUntilObserved { storage.value == 20 })
        await depot.waitForPendingObservations()
        #expect(try await depot.get(valueFor: key) == 20)
        #expect(storage.error == nil)
    }

    @Test("DepotValueStorage surfaces observation errors and clears them after a successful read")
    func singleValueObservationError() async throws {
        let depot = Depot()
        let key = Key.from("late", as: Int.self)

        // Not registered yet: the initial read fails.
        let storage = DepotValueStorage(depot: depot, key: key, initialValue: true)
        #expect(await waitUntilObserved { storage.error != nil })
        #expect(storage.value == nil)

        _ = depot.register(key: Key.from("late"), coder: .data(Int.self))
        try await depot.set(value: 7, for: key)
        #expect(await waitUntilObserved { storage.value == 7 })
        #expect(storage.error == nil)
    }

    @Test("DepotValueStorage surfaces write errors")
    func singleValueWriteError() async throws {
        let depot = Depot.temporary()
        defer { removeDirectory(of: depot) }
        let key = Key.from("unregistered", as: Int.self)

        let storage = DepotValueStorage(depot: depot, key: key, initialValue: false)
        storage.setValue(1)
        await storage.waitForPendingWritesForTesting()
        #expect(storage.error != nil)
    }

    @Test("DepotValueStorage is released when no longer referenced")
    func singleValueStorageIsReleased() async throws {
        let depot = Depot()
        _ = depot.register(key: Key.from("count"), coder: .data(Int.self))
        let key = Key.from("count", as: Int.self)
        try await depot.set(value: 1, for: key)

        weak var weakStorage: DepotValueStorage<Int>?
        do {
            let storage = DepotValueStorage(depot: depot, key: key, initialValue: true)
            weakStorage = storage
            #expect(await waitUntilObserved { storage.value == 1 })
        }
        #expect(await waitOnMain { weakStorage == nil })

        // Further changes must not resurrect or crash the released observer.
        try await depot.set(value: 2, for: key)
        await depot.waitForPendingObservations()
    }

    @Test("DepotValuesStorage delivers initial values, updates and removals", arguments: [false, true])
    func multiValuePropagation(fileBacked: Bool) async throws {
        let depot = makeDepot(fileBacked: fileBacked)
        defer { removeDirectory(of: depot) }
        let pattern = depot.register(key: Key.from("items" / .wildcard), coder: .data(Int.self))
        let itemA = Key.from("items" / "a", as: Int.self)
        let itemB = Key.from("items" / "b", as: Int.self)
        try await depot.set(value: 1, for: itemA)

        let storage = DepotValuesStorage(depot: depot, key: pattern, initialValues: true)
        #expect(await waitUntilObserved { storage.values == [1] })

        try await depot.set(value: 2, for: itemB)
        #expect(await waitUntilObserved { storage.values.sorted() == [1, 2] })

        try await depot.remove(valueFor: itemA)
        #expect(await waitUntilObserved { storage.values == [2] })

        try await depot.remove(valuesFor: pattern)
        #expect(await waitUntilObserved { storage.values.isEmpty })
        #expect(storage.error == nil)
    }

    @Test("DepotValuesStorage with initialValues: false waits for the first change")
    func multiValueWithoutInitialValues() async throws {
        let depot = Depot()
        let pattern = depot.register(key: Key.from("items" / .wildcard), coder: .data(Int.self))
        try await depot.set(value: 1, for: Key.from("items" / "a", as: Int.self))

        let storage = DepotValuesStorage(depot: depot, key: pattern, initialValues: false)
        await depot.waitForPendingObservations()
        #expect(storage.values.isEmpty)

        try await depot.set(value: 2, for: Key.from("items" / "b", as: Int.self))
        #expect(await waitUntilObserved { storage.values.sorted() == [1, 2] })
    }

    @Test("DepotValuesStorage surfaces observation errors")
    func multiValueObservationError() async throws {
        let depot = Depot()
        let storage = DepotValuesStorage(
            depot: depot,
            key: Key.from("unregistered" / .wildcard, as: Int.self),
            initialValues: true,
        )
        #expect(await waitUntilObserved { storage.error != nil })
        #expect(storage.values.isEmpty)
    }
}

// MARK: - Property wrappers hosted in SwiftUI (macOS)

#if canImport(AppKit)

@MainActor
@Suite("Observation adapters: property wrappers in SwiftUI")
struct ObservationPropertyWrapperTests {
    /// Collects what a hosted view observed during `body` evaluations.
    @MainActor
    final class Recorder<Value> {
        var rendered: [Value] = []
        var binding: Binding<Value>?
        var error: Error?
    }

    struct SingleValueView: View {
        @DepotValue
        var value: Int?
        let recorder: Recorder<Int?>

        init(_ wrapper: DepotValue<Int>, recorder: Recorder<Int?>) {
            _value = wrapper
            self.recorder = recorder
        }

        var body: some View {
            recorder.rendered.append(value)
            recorder.binding = $value
            recorder.error = _value.error
            return Text("\(value ?? -1)")
        }
    }

    struct MultiValueView: View {
        @DepotValues
        var values: [Int]
        let recorder: Recorder<[Int]>

        init(_ wrapper: DepotValues<Int>, recorder: Recorder<[Int]>) {
            _values = wrapper
            self.recorder = recorder
        }

        var body: some View {
            recorder.rendered.append(values.sorted())
            recorder.error = _values.error
            return Text("\(values.count)")
        }
    }

    private final class Host {
        let window: NSWindow
        let view: NSView

        @MainActor
        init(_ rootView: some View) {
            view = NSHostingView(rootView: rootView)
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
            view.layoutSubtreeIfNeeded()
        }
    }

    @Test("@DepotValue renders the stored value and re-renders on change")
    func depotValueRendersUpdates() async throws {
        let depot = Depot()
        _ = depot.register(key: Key.from("count"), coder: .data(Int.self))
        let key = Key.from("count", as: Int.self)
        try await depot.set(value: 1, for: key)

        let recorder = Recorder<Int?>()
        let host = Host(SingleValueView(DepotValue(key: key, depot: depot), recorder: recorder))
        #expect(await waitOnMain(pump: host.pump) { recorder.rendered.last == 1 })

        try await depot.set(value: 2, for: key)
        #expect(await waitOnMain(pump: host.pump) { recorder.rendered.last == 2 })

        try await depot.remove(valueFor: key)
        #expect(await waitOnMain(pump: host.pump) { recorder.rendered.last == .some(nil) })
        #expect(recorder.error == nil)
    }

    @Test("@DepotValue(definition:) registers the key and writes through its binding")
    func depotValueDefinitionAndBinding() async throws {
        let depot = Depot()
        let definition = KeyDefinition<Int>(path: "settings" / "volume", coder: .data(Int.self))

        let recorder = Recorder<Int?>()
        let host = Host(SingleValueView(DepotValue(definition: definition, depot: depot), recorder: recorder))
        #expect(await waitOnMain(pump: host.pump) { recorder.binding != nil && !recorder.rendered.isEmpty })

        recorder.binding?.wrappedValue = 5
        #expect(await waitOnMain(pump: host.pump) { recorder.rendered.last == 5 })
        #expect(try await depot.get(valueFor: Key.from("settings" / "volume", as: Int.self)) == 5)
        #expect(recorder.error == nil)
    }

    @Test("@DepotValues renders matching values and re-renders on change")
    func depotValuesRendersUpdates() async throws {
        let depot = Depot()
        let definition = PatternKeyDefinition<Int>(path: "items" / .wildcard, coder: .data(Int.self))
        _ = depot.register(definition)
        try await depot.set(value: 1, for: Key.from("items" / "a", as: Int.self))

        let recorder = Recorder<[Int]>()
        let host = Host(MultiValueView(DepotValues(definition: definition, depot: depot), recorder: recorder))
        #expect(await waitOnMain(pump: host.pump) { recorder.rendered.last == [1] })

        try await depot.set(value: 2, for: Key.from("items" / "b", as: Int.self))
        #expect(await waitOnMain(pump: host.pump) { recorder.rendered.last == [1, 2] })

        try await depot.remove(valueFor: Key.from("items" / "a", as: Int.self))
        #expect(await waitOnMain(pump: host.pump) { recorder.rendered.last == [2] })
        #expect(recorder.error == nil)
    }
}

#endif

#endif
