// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// A distinct prefix passed to `diskUsage(under:)` names directories, so its
/// components are limited by the directory budget, not by the leaf budget.
@Suite
struct DiskUsagePrefixBudgetTests {
    struct Scenario: Sendable, CustomTestStringConvertible {
        let codec: DepotFileNameCodec
        let byteCount: Int

        var testDescription: String {
            "\(codec.displayName), \(byteCount) bytes"
        }
    }

    /// Lengths around the leaf and directory limits: Base64url 186 (leaf) / 189 (directory),
    /// Base32 155 / 155.
    static let scenarios =
        [186, 187, 188, 189, 190].map { Scenario(codec: .base64URL, byteCount: $0) }
        + [154, 155, 156].map { Scenario(codec: .base32, byteCount: $0) }

    private enum Outcome: Equatable {
        case usage(fileCount: Int, totalBytes: Int64)
        case tooLong(byteCount: Int, maximumByteCount: Int)
    }

    private static func outcome(_ measure: () async throws -> Depot.DiskUsage) async -> Outcome? {
        do {
            let usage = try await measure()
            return .usage(fileCount: usage.fileCount, totalBytes: usage.totalBytes)
        } catch let DepotError.keyComponentTooLong(_, byteCount, maximumByteCount) {
            return .tooLong(byteCount: byteCount, maximumByteCount: maximumByteCount)
        } catch {
            Issue.record("Unexpected error \(error)")
            return nil
        }
    }

    @Test("an implicit prefix measures like the explicit globstar prefix", arguments: scenarios)
    func implicitPrefixUsesDirectoryBudget(scenario: Scenario) async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let depot = Depot(
            configuration: .init(directoryURL: directoryURL),
            overrides: .init(volumeSupportsCaseSensitiveNames: { _ in scenario.codec == .base64URL }),
        )
        depot.register(key: Key.all, coder: .json(Int.self))

        let component = String(repeating: "a", count: scenario.byteCount)
        let directoryLimit = scenario.codec.maximumIdentifierByteCount(isLeaf: false)
        if scenario.byteCount <= directoryLimit {
            try await depot.set(value: 9, for: Key.from(KeyPathExpression(component) / "value", as: Int.self))
        }

        let prefix = Key.from(KeyPathExpression(component))
        let explicit = Key.from(KeyPathExpression(component) / .globstar)

        let explicitSync = await Self.outcome { try depot.diskUsage(under: explicit) as Depot.DiskUsage }
        let implicitSync = await Self.outcome { try depot.diskUsage(under: prefix) as Depot.DiskUsage }
        let explicitAsync = await Self.outcome { try await depot.diskUsage(under: explicit) }
        let implicitAsync = await Self.outcome { try await depot.diskUsage(under: prefix) }

        if scenario.byteCount <= directoryLimit {
            guard case .usage(fileCount: 1, _)? = explicitSync else {
                Issue.record("The explicit prefix must count the stored value, got \(String(describing: explicitSync))")
                return
            }
        } else {
            #expect(
                explicitSync == .tooLong(byteCount: scenario.byteCount, maximumByteCount: directoryLimit)
            )
        }
        #expect(implicitSync == explicitSync)
        #expect(explicitAsync == explicitSync)
        #expect(implicitAsync == explicitSync)
    }
}
