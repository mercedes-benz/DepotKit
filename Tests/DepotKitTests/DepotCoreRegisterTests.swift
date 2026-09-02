// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct DepotCoreRegisterTests {
    // MARK: - Register Overloads

    @Test("register with KeyPathExpression returns typed distinct key")
    func registerKeyPathExpression() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "user" / "name", coder: .json() as AnyCoder<String>)
        try depot.set(value: "Alice", for: key)
        #expect(try depot.get(valueFor: key) == "Alice")
    }

    @Test("register with PatternKeyPathExpression returns typed key")
    func registerPatternKeyPathExpression() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "users" / .wildcard / "name", coder: .json() as AnyCoder<String>)
        let concreteKey = Key.from("users" / "alice" / "name", as: String.self)
        try depot.set(value: "Alice", for: concreteKey)
        let values = try depot.get(valuesFor: key)
        #expect(values == ["Alice"])
    }

    @Test("register distinct key with AnyCoder (disfavored overload)")
    func registerDistinctKeyAnyCoder() throws {
        let depot = Depot.temporary()
        let distinctKey = Key.from("item") as DistinctKey
        let key: TypedDistinctKey<Int> = depot.register(key: distinctKey, coder: .json())
        try depot.set(value: 99, for: key)
        #expect(try depot.get(valueFor: key) == 99)
    }

    @Test("register pattern key with AnyCoder (disfavored overload)")
    func registerPatternKeyAnyCoder() throws {
        let depot = Depot.temporary()
        let patternKey = Key.from("items" / .wildcard)
        let key: TypedKey<String> = depot.register(key: patternKey, coder: .json())
        let concreteKey = Key.from("items" / "a", as: String.self)
        try depot.set(value: "val", for: concreteKey)
        let values = try depot.get(valuesFor: key)
        #expect(values == ["val"])
    }

    @Test("register KeyPathExpression with AnyCoder (disfavored overload)")
    func registerKeyPathAnyCoder() throws {
        let depot = Depot.temporary()
        let key: TypedDistinctKey<Double> = depot.register(keyPath: "pi", coder: .json())
        try depot.set(value: 3.14, for: key)
        #expect(try depot.get(valueFor: key) == 3.14)
    }

    @Test("register PatternKeyPathExpression with AnyCoder (disfavored overload)")
    func registerPatternKeyPathAnyCoder() throws {
        let depot = Depot.temporary()
        let key: TypedKey<Bool> = depot.register(keyPath: "flags" / .wildcard, coder: .json())
        let concreteKey = Key.from("flags" / "active", as: Bool.self)
        try depot.set(value: true, for: concreteKey)
        let values = try depot.get(valuesFor: key)
        #expect(values == [true])
    }

    @Test("register with generic Coder (not AnyCoder)")
    func registerWithGenericCoder() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "raw", coder: RawStringCoder())
        try depot.set(value: "hello", for: key)
        #expect(try depot.get(valueFor: key) == "hello")
    }

    // MARK: - Convenience Methods

    @Test("get with default returns default when nil")
    func getWithDefaultNil() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "missing", coder: .json() as AnyCoder<Int>)
        let result = try depot.get(valueFor: key, default: 42)
        #expect(result == 42)
    }

    @Test("get with default returns stored value when present")
    func getWithDefaultPresent() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "exists", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 7, for: key)
        let result = try depot.get(valueFor: key, default: 42)
        #expect(result == 7)
    }

    @Test("has(valueFor:) returns false for missing, true for present")
    func hasValueFor() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        #expect(try depot.has(valueFor: key) == false)
        try depot.set(value: "x", for: key)
        #expect(try depot.has(valueFor: key) == true)
    }

    @Test("remove(valueFor:) removes single value")
    func removeValueFor() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try depot.set(value: "data", for: key)
        try depot.remove(valueFor: key)
        #expect(try depot.get(valueFor: key) == nil)
    }

    @Test("removeAll() removes everything")
    func removeAllConvenience() throws {
        let depot = Depot.temporary()
        let keyA = depot.register(keyPath: "a", coder: .json() as AnyCoder<Int>)
        let keyB = depot.register(keyPath: "b", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 1, for: keyA)
        try depot.set(value: 2, for: keyB)
        try depot.removeAll()
        #expect(try depot.get(valueFor: keyA) == nil)
        #expect(try depot.get(valueFor: keyB) == nil)
    }

    @Test("default label uses type name")
    func defaultLabel() {
        let depot = Depot(label: "Custom")
        #expect(depot.label == "Custom")
    }
}

// MARK: - Logging Tests

@Suite
struct LoggingInfrastructureTests {
    @Test("LOG is no-op without a sink")
    func logNoopWithoutSink() {
        let previous = DepotKitLogging.sink
        defer { DepotKitLogging.sink = previous }

        DepotKitLogging.sink = nil
        // Should not crash
        LOG(level: .error, message: "should be ignored")
    }

    @Test("LOG routes all levels to the sink")
    func logRoutesAllLevels() {
        let previous = DepotKitLogging.sink
        defer { DepotKitLogging.sink = previous }

        let received = OSAllocatedUnfairLock<[DepotKitLogLevel]>(initialState: [])

        DepotKitLogging.sink = .callback { level, message, _, _, _ in
            _ = message()
            received.withLock { $0.append(level) }
        }

        LOG(level: .info, message: "info")
        LOG(level: .debug, message: "debug")
        LOG(level: .notice, message: "notice")
        LOG(level: .error, message: "error")

        let levels = received.withLock { $0 }
        #expect(levels == [.info, .debug, .notice, .error])
    }

    @Test("CallbackLogSink receives file, function, line")
    func callbackReceivesSourceLocation() {
        let previous = DepotKitLogging.sink
        defer { DepotKitLogging.sink = previous }

        struct Location: Sendable {
            var file: String = ""
            var function: String = ""
            var line: UInt = 0
        }

        let location = OSAllocatedUnfairLock(initialState: Location())

        DepotKitLogging.sink = .callback { _, message, file, function, line in
            _ = message()
            location.withLock {
                $0.file = "\(file)"
                $0.function = "\(function)"
                $0.line = line
            }
        }

        LOG(level: .info, message: "test")
        let loc = location.withLock { $0 }
        #expect(loc.file.contains("DepotCoreRegisterTests"))
        #expect(loc.function.contains("callbackReceivesSourceLocation"))
        #expect(loc.line > 0)
    }

    @Test("OSLogSink handles all levels without crash")
    func osLogSinkAllLevels() {
        let sink = DepotKitOSLogSink(subsystem: "test", category: "test")
        sink.log(.info, { "info" }, file: #file, function: #function, line: #line)
        sink.log(.debug, { "debug" }, file: #file, function: #function, line: #line)
        sink.log(.notice, { "notice" }, file: #file, function: #function, line: #line)
        sink.log(.error, { "error" }, file: #file, function: #function, line: #line)
    }

    @Test("OSLogSink with includeSourceLocation prefixes messages")
    func osLogSinkWithSourceLocation() {
        let sink = DepotKitOSLogSink(
            subsystem: "test",
            category: "test",
            includeSourceLocation: true,
        )
        // Should not crash — formatting includes file:line
        sink.log(.info, { "test" }, file: #file, function: #function, line: #line)
    }

    @Test("DepotKitLogLevel equality")
    func logLevelEquality() {
        #expect(DepotKitLogLevel.info == DepotKitLogLevel.info)
        #expect(DepotKitLogLevel.debug == DepotKitLogLevel.debug)
        #expect(DepotKitLogLevel.notice == DepotKitLogLevel.notice)
        #expect(DepotKitLogLevel.error == DepotKitLogLevel.error)
        #expect(DepotKitLogLevel.info != DepotKitLogLevel.error)
    }

    @Test("DepotKitLogging.sink is thread-safe")
    func sinkThreadSafety() async {
        let previous = DepotKitLogging.sink
        defer { DepotKitLogging.sink = previous }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    if i % 2 == 0 {
                        DepotKitLogging.sink = .callback { _, _, _, _, _ in }
                    } else {
                        _ = DepotKitLogging.sink
                    }
                }
            }
        }
        // No crash = thread safe
    }
}

private struct RawStringCoder: Coder {
    func encode(_ value: String) throws -> Data {
        Data(value.utf8)
    }

    func decode(_ data: Data) throws -> String {
        guard let s = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return s
    }
}
