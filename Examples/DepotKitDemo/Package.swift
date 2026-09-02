// swift-tools-version: 6.2
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import PackageDescription

let package = Package(
    name: "DepotKitDemo",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "DepotKitDemo",
            dependencies: [
                .product(name: "DepotKit", package: "depotkit"),
                .product(name: "DepotKitCombine", package: "depotkit"),
                .product(name: "DepotKitObservation", package: "depotkit"),
            ],
            path: "Sources",
            resources: [
                .copy("Resources/AppIcon.png")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
