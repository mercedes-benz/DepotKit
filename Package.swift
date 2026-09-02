// swift-tools-version: 6.2
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "DepotKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .tvOS(.v17),
        .macOS(.v14),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "DepotKit",
            targets: ["DepotKit"]
        ),
        .library(
            name: "DepotKitCombine",
            targets: ["DepotKitCombine"]
        ),
        .library(
            name: "DepotKitObservation",
            targets: ["DepotKitObservation"]
        )
    ],
    traits: [
        .trait(name: "Combine", description: "Include Combine adapters (ObservableDepot → publishers)."),
        .trait(name: "Observation", description: "Include @Observable adapters."),
        .default(enabledTraits: ["Combine", "Observation"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "602.0.0")
    ],
    targets: [
        // MARK: - Macros
        .macro(
            name: "DepotKitMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ],
            path: "Sources/DepotKitMacros"
        ),
        // MARK: - DepotKit
        .target(
            name: "DepotKit",
            dependencies: [
                .byName(name: "DepotKitMacros")
            ],
            path: "Sources/DepotKit",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "DepotKitCombine",
            dependencies: [
                .byName(name: "DepotKit")
            ],
            path: "Sources/DepotKitCombine"
        ),
        .target(
            name: "DepotKitObservation",
            dependencies: [
                .byName(name: "DepotKit")
            ],
            path: "Sources/DepotKitObservation"
        ),
        // MARK: - Tests
        .testTarget(
            name: "DepotKitTests",
            dependencies: [
                .byName(name: "DepotKit"),
                .byName(name: "DepotKitCombine", condition: .when(traits: ["Combine"])),
                .byName(name: "DepotKitObservation", condition: .when(traits: ["Observation"]))
            ],
            path: "Tests/DepotKitTests",
            swiftSettings: [
                .define("COMBINE_ENABLED", .when(traits: ["Combine"])),
                .define("OBSERVATION_ENABLED", .when(traits: ["Observation"]))
            ]
        ),
        .testTarget(
            name: "DepotKitMacroTests",
            dependencies: [
                .byName(name: "DepotKitMacros"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            path: "Tests/DepotKitMacroTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
