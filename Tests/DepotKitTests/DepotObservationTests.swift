// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

private final class ObservationTestConfiguration {
    let depots: [Depot]
    let baseDepotURL: URL

    init() {
        let encryptionConfiguration = try! EncryptionConfiguration(
            cipher: .aesGCM,
            hashFunction: .sha256,
            key: EncryptionConfiguration.generateKey(),
        )
        baseDepotURL = try! DepotConfiguration.directoryURL(
            in: .caches,
            name: "DepotObservationTests-\(UUID().uuidString)",
        )

        depots = [
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    memoryCache: .disabled
                )
            ),
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    encryption: encryptionConfiguration,
                    memoryCache: .disabled
                )
            ),
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    memoryCache: .default
                )
            ),
            Depot(
                configuration: .init(
                    directoryURL: baseDepotURL.appendingPathComponent(UUID().uuidString),
                    encryption: encryptionConfiguration,
                    memoryCache: .default
                )
            ),
        ]
    }

    deinit {
        let baseDepotURL = baseDepotURL

        Task { @concurrent in
            do {
                try FileManager.default.removeItem(at: baseDepotURL)
            } catch {
                // ignore
            }
        }
    }
}

@Suite
struct DepotObservationTests {
    @Suite
    struct ObserveTests {
        @Test("cancels observation via task cancellation")
        func cancelsObservation() async throws {
            let testConfiguration = ObservationTestConfiguration()

            for depot in testConfiguration.depots {
                depot.register(key: Key.all, coder: .data(String.self))

                let key = Key.from("test", as: String.self)
                let receivedValues = OSAllocatedUnfairLock<[String]>(initialState: [])

                let stream = depot.values(for: key, initialValue: false)
                let task = Task {
                    for await case .success(let v?) in stream {
                        receivedValues.withLock { $0.append(v) }
                    }
                }

                try await depot.set(value: "1", for: key)
                await depot.waitForPendingObservations()
                task.cancel()
                await task.value

                try await depot.set(value: "2", for: key)
                await depot.waitForPendingObservations()

                let receivedValuesFinal = receivedValues.withLock { $0 }
                #expect(receivedValuesFinal == ["1"])
            }
        }

        @Test("delivers latest value when mutations are rapid")
        func deliversLatestValue() async throws {
            let testConfiguration = ObservationTestConfiguration()

            for depot in testConfiguration.depots {
                depot.register(key: Key.all, coder: .data(String.self))

                let key = Key.from("test" / "some" / "thing", as: String.self)
                let receivedResults = OSAllocatedUnfairLock<[Result<String?, Error>]>(initialState: [])

                let stream = depot.values(for: key, initialValue: false)
                let task = Task {
                    for await result in stream {
                        receivedResults.withLock { $0.append(result) }
                    }
                }

                try await depot.set(value: "1", for: key)
                await depot.waitForPendingObservations()

                try await depot.set(value: "2", for: key)
                await depot.waitForPendingObservations()

                try await depot.set(value: nil, for: key)
                await depot.waitForPendingObservations()

                task.cancel()
                await task.value

                let results = receivedResults.withLock { $0 }
                #expect(results.count == 3)
                #expect(try results[0].get() == "1")
                #expect(try results[1].get() == "2")
                #expect(try results[2].get() == nil)
            }
        }

        @Test("reports initial value then subsequent updates")
        func reportsInitialValue() async throws {
            let testConfiguration = ObservationTestConfiguration()

            for depot in testConfiguration.depots {
                depot.register(key: Key.all, coder: .data(String.self))

                let key = Key.from("test" / "some" / "thing", as: String.self)
                let receivedValues = OSAllocatedUnfairLock<[String]>(initialState: [])

                try await depot.set(value: "1", for: key)
                try await depot.set(value: "2", for: key)

                let stream = depot.values(for: key, initialValue: true)
                let task = Task {
                    for await case .success(let v?) in stream {
                        receivedValues.withLock { $0.append(v) }
                    }
                }

                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { !$0.isEmpty } })

                let afterInitial = receivedValues.withLock { $0 }
                #expect(afterInitial.last == "2")

                try await depot.set(value: "4", for: key)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.last == "4" } })

                task.cancel()
                await task.value

                let receivedValuesFinal = receivedValues.withLock { $0 }
                #expect(receivedValuesFinal.last == "4")
                #expect(receivedValuesFinal.contains("2"))
            }
        }
    }

    @Suite
    struct ObserveValuesTests {
        @Test("cancels observation via task cancellation")
        func cancelsObservation() async throws {
            let testConfiguration = ObservationTestConfiguration()

            for depot in testConfiguration.depots {
                depot.register(key: Key.all, coder: .data(String.self))

                let key = Key.from("test", as: String.self)
                let receivedValues = OSAllocatedUnfairLock<[[String]]>(initialState: [])

                let stream = depot.values(for: key, initialValues: false)
                let task = Task {
                    for await result in stream {
                        switch result {
                        case let .success(values):
                            receivedValues.withLock { $0.append(values.sorted()) }
                        case .failure:
                            Issue.record()
                        }
                    }
                }

                try await depot.set(value: "1", for: key)
                await depot.waitForPendingObservations()
                task.cancel()
                await task.value

                try await depot.set(value: "2", for: key)
                await depot.waitForPendingObservations()

                let receivedValuesFinal = receivedValues.withLock { $0 }
                #expect(receivedValuesFinal == [["1"]])
            }
        }

        @Test("calls update as expected")
        func callsUpdate() async throws {
            let testConfiguration = ObservationTestConfiguration()

            for depot in testConfiguration.depots {
                depot.register(key: Key.all, coder: .data(String.self))
                let key4 = depot.register(
                    key: Key.from("accounts" / "one"),
                    coder: .data(Data.self),
                )

                let key = Key.from("entity" / .wildcard / "status", as: String.self)
                let key1 = Key.from("entity" / "a" / "status", as: String.self)
                let key2 = Key.from("entity" / "b" / "status", as: String.self)
                let key3 = Key.from("entity" / "c" / "status", as: String.self)

                let receivedValues = OSAllocatedUnfairLock<[[String]]>(initialState: [])

                let stream = depot.values(for: key, initialValues: false)
                let task = Task {
                    for await result in stream {
                        switch result {
                        case let .success(values):
                            receivedValues.withLock { $0.append(values.sorted()) }
                        case .failure:
                            Issue.record()
                        }
                    }
                }

                try await depot.set(value: "1", for: key1)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 1 } })

                try await depot.remove(valuesFor: Key.all)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 2 } })

                try await depot.set(value: "2", for: key2)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 3 } })

                try await depot.set(value: "3", for: key3)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 4 } })

                try await depot.set(value: nil, for: key3)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 5 } })

                try await depot.remove(valuesFor: key1)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 6 } })

                try await depot.set(value: "4".dataRepresentation, for: key4)
                await depot.waitForPendingObservations()

                try await depot.remove(valuesFor: Key.from("test" / .wildcard))
                await depot.waitForPendingObservations()

                try await depot.remove(valuesFor: Key.all)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 7 } })
                task.cancel()
                await task.value

                let receivedValuesFinal = receivedValues.withLock { $0 }
                #expect(receivedValuesFinal == [["1"], [], ["2"], ["2", "3"], ["2"], ["2"], []])
            }
        }

        @Test("reports initial values")
        func reportsInitialValues() async throws {
            let testConfiguration = ObservationTestConfiguration()

            for depot in testConfiguration.depots {
                depot.register(key: Key.all, coder: .data(String.self))

                let key = Key.from("entity" / .wildcard / "status", as: String.self)
                let key1 = Key.from("entity" / "a" / "status", as: String.self)
                let key2 = Key.from("entity" / "b" / "status", as: String.self)
                let key3 = Key.from("entity" / "c" / "status", as: String.self)

                let receivedValues = OSAllocatedUnfairLock<[[String]]>(initialState: [])

                try await depot.set(value: "1", for: key1)
                try await depot.set(value: "2", for: key2)

                let stream = depot.values(for: key, initialValues: true)
                let task = Task {
                    for await result in stream {
                        switch result {
                        case let .success(values):
                            receivedValues.withLock { $0.append(values.sorted()) }
                        case .failure:
                            Issue.record()
                        }
                    }
                }

                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 1 } })

                try await depot.set(value: "3", for: key3)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 2 } })

                try await depot.remove(valuesFor: Key.all)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 3 } })

                try await depot.set(value: "2", for: key2)
                await depot.waitForPendingObservations()
                #expect(await waitUntil { receivedValues.withLock { $0.count >= 4 } })
                task.cancel()
                await task.value

                let receivedValuesFinal = receivedValues.withLock { $0 }
                #expect(receivedValuesFinal == [["1", "2"], ["1", "2", "3"], [], ["2"]])
            }
        }
    }
}
