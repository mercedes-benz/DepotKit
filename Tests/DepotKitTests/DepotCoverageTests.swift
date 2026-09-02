// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct DepotCoverageTests {
    // MARK: - Multi-process support init

    @Test("init with multi-process support sets up changeTracker and signal")
    func multiProcessInit() {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(
                directoryURL: url,
                enableMultiProcessSupport: true,
            ),
        )
        #expect(depot.externalChangesDetected != nil)
        #expect(depot.changeTracker != nil)
    }

    // MARK: - Reserved key guards

    @Test("get with reserved metadata key throws reservedKey")
    func getReservedKeyThrows() {
        let depot = Depot.temporary()
        let reservedKey = TypedDistinctKey<String>(
            DistinctKey([KeyComponent.segment(identifier: "\(Depot.HiddenKeyPrefix)META")])
        )

        #expect(throws: DepotError.self) {
            _ = try depot.get(valueFor: reservedKey)
        }
    }

    @Test("set with reserved metadata key throws reservedKey")
    func setReservedKeyThrows() {
        let depot = Depot.temporary()
        let reservedKey = TypedDistinctKey<String>(
            DistinctKey([KeyComponent.segment(identifier: "\(Depot.HiddenKeyPrefix)META")])
        )

        #expect(throws: DepotError.self) {
            try depot.set(value: "x", for: reservedKey)
        }
    }

    // MARK: - Memory cache paths

    @Test("reading from cache-enabled depot exercises cache double-check")
    func cacheDoubleCheck() throws {
        let depot = Depot.temporary(memoryCache: .default)
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try depot.set(value: "hello", for: key)

        // First read populates cache
        let v1 = try depot.get(valueFor: key)
        #expect(v1 == "hello")

        // Second read hits cache (fast path outside lock)
        let v2 = try depot.get(valueFor: key)
        #expect(v2 == "hello")
    }

    @Test("reading missing key from cached depot returns nil via cache")
    func cacheMissAbsent() throws {
        let depot = Depot.temporary(memoryCache: .default)
        let key = depot.register(keyPath: "missing", coder: .json() as AnyCoder<String>)

        // First read: cache miss, no file on disk → sets confirmedAbsent
        let v1 = try depot.get(valueFor: key)
        #expect(v1 == nil)

        // Second read: cache confirms absent (fast path)
        let v2 = try depot.get(valueFor: key)
        #expect(v2 == nil)
    }

    // MARK: - Memory-only type mismatch

    @Test("memory-only get throws mismatchedTypes on wrong type")
    func memoryOnlyTypeMismatch() throws {
        let depot = Depot(label: "TypeMismatch")
        let stringKey = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try depot.set(value: "hello", for: stringKey)

        // Construct a typed key pointing to the same path but with Int type
        let intKey = TypedDistinctKey<Int>(DistinctKey(stringKey.components))

        #expect(throws: DepotError.self) {
            _ = try depot.get(valueFor: intKey)
        }
    }

    @Test("memory-only get valuesFor throws mismatchedTypes on wrong type")
    func memoryOnlyGetValuesMismatch() throws {
        let depot = Depot(label: "ValsMismatch")
        let stringKey = depot.register(
            key: Key.from("items" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )
        let concreteKey = Key.from("items" / "a", as: String.self)
        try depot.set(value: "hello", for: concreteKey)

        // Try to read same pattern as Int
        let intPattern = TypedKey<Int>(uncheckedKey: Key(stringKey.components))

        #expect(throws: DepotError.self) {
            _ = try depot.get(valuesFor: intPattern)
        }
    }

    @Test("memory-only availableValues collects type mismatch errors")
    func memoryOnlyAvailableValuesMismatch() throws {
        let depot = Depot(label: "AvailMismatch")
        let stringKey = depot.register(
            key: Key.from("data" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )
        let concreteKey = Key.from("data" / "x", as: String.self)
        try depot.set(value: "text", for: concreteKey)

        // Try to read as Int
        let intPattern = TypedKey<Int>(uncheckedKey: Key(stringKey.components))
        let result = try depot.get(availableValuesFor: intPattern)
        #expect(result.values.isEmpty)
        #expect(result.errors.count == 1)
    }

    // MARK: - Sync clearCache

    @Test("sync clearCache evicts cached entries")
    func syncClearCache() throws {
        let depot = Depot.temporary(memoryCache: .default)
        let key = depot.register(keyPath: "cached", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 42, for: key)
        _ = try depot.get(valueFor: key)  // populate cache

        depot.clearCache()

        // Still readable from disk
        let result = try depot.get(valueFor: key)
        #expect(result == 42)
    }

    // MARK: - Convenience initializers

    @Test("convenience init with directory and name")
    func convenienceInitDirectoryName() throws {
        let depot = try Depot(name: "CoverageTest-\(UUID().uuidString)")
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try depot.set(value: "works", for: key)
        #expect(try depot.get(valueFor: key) == "works")
    }

    // MARK: - Remove with Key.all (globstar reset path)

    @Test("remove valuesFor Key.all triggers reset path")
    func removeKeyAllResetsDepot() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try depot.set(value: "data", for: key)

        try depot.remove(valuesFor: Key.all)

        #expect(try depot.get(valueFor: key) == nil)
    }

    // MARK: - isExcludedFromBackup

    @Test("depot with isExcludedFromBackup sets resource values")
    func excludedFromBackup() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(
                directoryURL: url,
                isExcludedFromBackup: true,
            ),
        )
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try depot.set(value: "backup-test", for: key)

        // Verify the file has the backup exclusion resource value
        let distinctKey = DistinctKey(key.components)
        let fileURL = distinctKey.getFileURL(from: url)
        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // MARK: - checkForExternalChanges detecting changes

    @Test("checkForExternalChanges detects external modifications")
    func checkForExternalChangesDetectsModification() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(
                directoryURL: url,
                enableMultiProcessSupport: true,
            ),
        )
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try depot.set(value: "original", for: key)

        // Simulate external modification by writing to the file directly
        let distinctKey = DistinctKey(key.components)
        let fileURL = distinctKey.getFileURL(from: url)
        let newData = try (AnyCoder<String>.json() as AnyCoder<String>).encode("modified")
        try newData.write(to: fileURL, options: .atomic)

        // Touch the file with a new modification date
        var resourceValues = URLResourceValues()
        resourceValues.contentModificationDate = Date().addingTimeInterval(10)
        var mutableURL = fileURL
        try mutableURL.setResourceValues(resourceValues)

        try depot.checkForExternalChanges()

        // Cache should be invalidated, reads new value from disk
        let result = try depot.get(valueFor: key)
        #expect(result == "modified")
    }

    @Test("checkForExternalChanges detects external removal")
    func checkForExternalChangesDetectsRemoval() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(
                directoryURL: url,
                enableMultiProcessSupport: true,
                memoryCache: .default
            )
        )
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try depot.set(value: "exists", for: key)
        _ = try depot.get(valueFor: key)  // populate cache

        // Simulate external deletion
        let distinctKey = DistinctKey(key.components)
        let fileURL = distinctKey.getFileURL(from: url)
        try FileManager.default.removeItem(at: fileURL)

        try depot.checkForExternalChanges()

        // Cache should be invalidated, value is gone
        let result = try depot.get(valueFor: key)
        #expect(result == nil)
    }

    // MARK: - Read-only depot createMetadata path

    @Test("read-only depot does not throw on init if metadata exists")
    func readOnlyWithExistingMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)

        // First create a writable depot to establish metadata
        let writable = Depot(configuration: .init(directoryURL: url))
        let key = writable.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try writable.set(value: "data", for: key)

        // Now open as read-only
        let readOnly = Depot(configuration: .init(directoryURL: url, readOnly: true))
        let roKey = readOnly.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        #expect(try readOnly.get(valueFor: roKey) == "data")
    }

    // MARK: - Remove with single wildcard key

    @Test("remove valuesFor single wildcard only removes one-level keys")
    func removeWithSingleWildcard() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key([.wildcard]), coder: .json() as AnyCoder<String>)
        _ = depot.register(key: Key.from("a" / .wildcard), coder: .json() as AnyCoder<String>)

        let topKey = Key.from("top", as: String.self)
        let nestedKeyA = Key.from("a" / "1", as: String.self)
        let nestedKeyB = Key.from("a" / "2", as: String.self)

        try depot.set(value: "top", for: topKey)
        try depot.set(value: "x", for: nestedKeyA)
        try depot.set(value: "y", for: nestedKeyB)

        // [.wildcard] matches exactly one component — only "top" should be removed
        try depot.remove(valuesFor: Key([.wildcard]))

        #expect(try depot.get(valueFor: topKey) == nil)
        #expect(try depot.get(valueFor: nestedKeyA) == "x")
        #expect(try depot.get(valueFor: nestedKeyB) == "y")
    }

    @Test("remove valuesFor globstar triggers reset path")
    func removeWithGlobstar() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("a" / .wildcard), coder: .json() as AnyCoder<String>)
        let keyA = Key.from("a" / "1", as: String.self)
        let keyB = Key.from("a" / "2", as: String.self)
        try depot.set(value: "x", for: keyA)
        try depot.set(value: "y", for: keyB)

        // [.globstar] (Key.all) triggers the reset fast path
        try depot.remove(valuesFor: Key.all)

        #expect(try depot.get(valueFor: keyA) == nil)
        #expect(try depot.get(valueFor: keyB) == nil)
    }

    // MARK: - Multi-process init with logging

    @Test("multi-process init logs initialization message")
    func multiProcessInitWithLogging() {
        let previous = DepotKitLogging.sink
        defer { DepotKitLogging.sink = previous }

        let logged = OSAllocatedUnfairLock(initialState: false)
        DepotKitLogging.sink = .callback { _, message, _, _, _ in
            let msg = message()
            if msg.contains("multiProcess: true") {
                logged.withLock { $0 = true }
            }
        }

        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        _ = Depot(
            configuration: .init(
                directoryURL: url,
                enableMultiProcessSupport: true,
            ),
        )

        #expect(logged.withLock { $0 } == true)
    }

    // MARK: - removeFilePresenter no-op paths

    @Test("removeFilePresenter is no-op without multi-process support")
    func removeFilePresenterNoop() throws {
        let depot = Depot.temporary()
        // Should not throw, just early-return
        try depot.removeFilePresenter()
    }

    @Test("removeFilePresenter is no-op on memory-only depot")
    func removeFilePresenterMemoryOnly() throws {
        let depot = Depot(label: "mem")
        try depot.removeFilePresenter()
    }

    // MARK: - createMetadata read-only guard

    @Test("read-only depot throws on reset")
    func readOnlyResetThrows() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        // Create metadata first
        _ = Depot(configuration: .init(directoryURL: url))

        let depot = Depot(configuration: .init(directoryURL: url, readOnly: true))
        #expect(throws: DepotError.self) {
            try depot.reset()
        }
    }
}
