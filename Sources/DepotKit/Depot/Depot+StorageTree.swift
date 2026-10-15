// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

extension Depot {
    /// Returns an ASCII tree of the depot's registered keys.
    ///
    /// The tree mirrors the key-path hierarchy: each registered key appears as
    /// a leaf (or intermediate node) in the tree, with pattern components
    /// rendered as `*` or `**`. Leaf nodes show the value type and coder chain;
    /// keys with a registered expiry include the duration.
    ///
    /// ```
    /// WeatherDepot
    /// ├── cities
    /// │   └── * [City] .json(City) (pattern)
    /// ├── forecasts
    /// │   └── * [Forecast] .json(Forecast).compressed(.zlib) (pattern, expires: 30m)
    /// ├── settings
    /// │   └── app [AppSettings] .json(AppSettings).versioned(v2)
    /// └── stats
    ///     └── lastRefresh [Date] .json(Date)
    /// ```
    ///
    /// - Returns: A multi-line string suitable for logging or debug output.
    public func storageTree() -> String {
        let registeredKeys = core.keys.sorted()

        guard !registeredKeys.isEmpty else {
            return "\(label) (empty)"
        }

        var root = TreeNode(label: label)

        for key in registeredKeys {
            let expiry = core.expiry(for: key)
            let info = core.registrationInfo(for: key)
            root.insert(
                components: key.components[...],
                isPattern: !key.isDistinct,
                expiry: expiry,
                valueType: info?.valueType,
                coderDescription: info?.coderDescription
            )
        }

        var lines: [String] = []
        root.render(into: &lines, prefix: "", isRoot: true)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Tree node

private struct TreeNode {
    let label: String
    var children: [TreeNode] = []
    var isPattern = false
    var expiry: Duration?
    var valueType: String?
    var coderDescription: String?

    mutating func insert(
        components: ArraySlice<KeyComponent>,
        isPattern: Bool,
        expiry: Duration?,
        valueType: String?,
        coderDescription: String?
    ) {
        guard let first = components.first else {
            return
        }

        let name = first.treeName
        let remaining = components.dropFirst()

        if let index = children.firstIndex(where: { $0.label == name }) {
            if remaining.isEmpty {
                children[index].isPattern = isPattern
                children[index].expiry = expiry
                children[index].valueType = valueType
                children[index].coderDescription = coderDescription
            } else {
                children[index].insert(
                    components: remaining,
                    isPattern: isPattern,
                    expiry: expiry,
                    valueType: valueType,
                    coderDescription: coderDescription
                )
            }
        } else {
            var child = TreeNode(label: name)
            if remaining.isEmpty {
                child.isPattern = isPattern
                child.expiry = expiry
                child.valueType = valueType
                child.coderDescription = coderDescription
            } else {
                child.insert(
                    components: remaining,
                    isPattern: isPattern,
                    expiry: expiry,
                    valueType: valueType,
                    coderDescription: coderDescription
                )
            }
            children.append(child)
        }
    }

    func render(into lines: inout [String], prefix: String, isRoot: Bool) {
        if isRoot {
            lines.append(label)
        }

        for (index, child) in children.enumerated() {
            let isLast = index == children.count - 1
            let connector = isLast ? "└── " : "├── "
            let childPrefix = isLast ? "    " : "│   "

            var line = prefix + connector + child.label
            line += child.typeAndCoderSuffix
            line += child.annotation
            lines.append(line)

            child.render(into: &lines, prefix: prefix + childPrefix, isRoot: false)
        }
    }

    private var typeAndCoderSuffix: String {
        guard let valueType else { return "" }
        var result = " [\(valueType)]"
        if let coderDescription {
            result += " \(coderDescription)"
        }
        return result
    }

    private var annotation: String {
        var parts: [String] = []
        if isPattern { parts.append("pattern") }
        if let expiry { parts.append("expires: \(expiry.treeDescription)") }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }
}

// MARK: - Helpers

extension KeyComponent {
    fileprivate var treeName: String {
        switch self {
        case .wildcard: "*"
        case .globstar: "**"
        case let .segment(identifier): identifier
        }
    }
}

extension Duration {
    fileprivate var treeDescription: String {
        let total = components
        let seconds = total.seconds
        let attos = total.attoseconds

        if seconds == 0, attos > 0 {
            let ms = attos / 1_000_000_000_000_000
            return "\(ms)ms"
        }

        if seconds < 60 {
            return "\(seconds)s"
        }

        if seconds < 3600 {
            let m = seconds / 60
            let s = seconds % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }

        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
