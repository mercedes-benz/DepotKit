// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct ExternalChangesTests {
    // MARK: - External Changes Signal

    @Test("externalChangesDetected is nil without multi-process")
    func externalChangesDetectedNilWithoutMultiProcess() {
        let depot = Depot.temporary()
        #expect(depot.externalChangesDetected == nil)
    }

    @Test("externalChangesDetected fires on signal emission")
    func externalChangesDetectedFires() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true),
        )

        let fired = OSAllocatedUnfairLock(initialState: false)
        _ = depot.externalChangesDetected?.observe { _ in
            fired.withLock { $0 = true }
        }

        depot.externalChangesDetected?.emit()
        Thread.sleep(forTimeInterval: 0.1)

        #expect(fired.withLock { $0 } == true)
    }

    // MARK: - automaticallyCheckForExternalChanges

    #if os(macOS)
    @Test("automaticallyCheckForExternalChanges adds file presenter on macOS")
    func autoCheckAddsFilePresenter() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true),
        )

        try depot.automaticallyCheckForExternalChanges()

        // Calling again should be a no-op (already registered)
        try depot.automaticallyCheckForExternalChanges()
    }

    @Test("automaticallyCheckForExternalChanges debounces signal")
    func autoCheckDebounces() async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true),
        )

        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try await depot.set(value: "original", for: key)

        try depot.automaticallyCheckForExternalChanges(debounceInterval: 0.1)

        // Simulate external change
        let distinctKey = DistinctKey(key.components)
        let fileURL = distinctKey.getFileURL(from: url)
        let newData = try (AnyCoder<String>.json() as AnyCoder<String>).encode("updated")
        try newData.write(to: fileURL, options: .atomic)

        var resourceValues = URLResourceValues()
        resourceValues.contentModificationDate = Date().addingTimeInterval(10)
        var mutableURL = fileURL
        try mutableURL.setResourceValues(resourceValues)

        // Emit the signal multiple times rapidly
        depot.externalChangesDetected?.emit()
        depot.externalChangesDetected?.emit()
        depot.externalChangesDetected?.emit()

        // Wait for debounce + check
        try await Task.sleep(for: .seconds(0.5))

        let result = try await depot.get(valueFor: key)
        #expect(result == "updated")
    }
    #endif

    // MARK: - addFilePresenter / removeFilePresenter with multi-process

    @Test("addFilePresenter creates lock file and registers presenter")
    func addFilePresenterCreatesLock() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true),
        )

        // Call addFilePresenter BEFORE any writes — this should create the lock file
        try depot.addFilePresenter()

        let lockURL = url.appendingPathComponent("\(Depot.HiddenKeyPrefix)LOCK")
        #expect(FileManager.default.fileExists(atPath: lockURL.path))

        // Calling again should update the existing lock (touch path)
        try depot.removeFilePresenter()
        try depot.addFilePresenter()

        try depot.removeFilePresenter()
    }

    @Test("removeFilePresenter after addFilePresenter works")
    func removeFilePresenterAfterAdd() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true),
        )

        try depot.addFilePresenter()
        try depot.removeFilePresenter()
    }

    @Test("addFilePresenter is no-op without multi-process")
    func addFilePresenterNoopNoMultiProcess() throws {
        let depot = Depot.temporary()
        try depot.addFilePresenter()
    }

    @Test("addFilePresenter is no-op for memory-only depot")
    func addFilePresenterMemoryOnly() throws {
        let depot = Depot(label: "mem")
        try depot.addFilePresenter()
    }

    // MARK: - Multi-process coordinated reads

    @Test("verifyIntegrity on multi-process depot uses coordinated read")
    func verifyIntegrityMultiProcess() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true),
        )
        // verifyIntegrity reads metadata via coordinated access
        try depot.verifyIntegrity()
    }

    @Test("presentedItemDidChange triggers external changes signal")
    func presentedItemDidChange() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true),
        )

        let signalFired = OSAllocatedUnfairLock(initialState: false)
        _ = depot.externalChangesDetected?.observe { _ in
            signalFired.withLock { $0 = true }
        }

        // Directly call the file manager's presentedItemDidChange
        depot.fileManager?.presentedItemDidChange()

        Thread.sleep(forTimeInterval: 0.05)
        #expect(signalFired.withLock { $0 } == true)
    }
}
