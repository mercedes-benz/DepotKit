// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct DepotChangeTrackerTests {
    @Test("works as expected")
    func works() async throws {
        let subject = DepotChangeTracker()

        subject.setModificationDates([
            Key.from("1"): Date(timeIntervalSince1970: 1),
            Key.from("2"): Date(timeIntervalSince1970: 2),
            Key.from("3"): Date(timeIntervalSince1970: 3),
            Key.from("4"): Date(timeIntervalSince1970: 4),
            Key.from("5"): Date(timeIntervalSince1970: 5),
        ])

        subject.modified(
            key: Key.from("1"),
            at: Date(timeIntervalSince1970: 101),
        )

        subject.removed(
            key: Key.from("4"),
        )

        let diff = subject.setModificationDates([
            Key.from("1"): Date(timeIntervalSince1970: 101),
            Key.from("2"): Date(timeIntervalSince1970: 200),
            Key.from("3"): Date(timeIntervalSince1970: 3),
            Key.from("6"): Date(timeIntervalSince1970: 6),
        ])

        #expect(
            diff.modified.sorted() == [Key.from("2"), Key.from("6")],
        )
        #expect(diff.removed.sorted() == [Key.from("5")])
    }
}
