// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpiderbrainKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        // Legacy target (keeping existing code working)
        .library(name: "SpiderbrainKit", targets: ["SpiderbrainKit"]),

        // New architecture targets (empty for now, will migrate incrementally)
        .library(name: "InkCore", targets: ["InkCore"]),
        .library(name: "InkRendering", targets: ["InkRendering"]),
        .library(name: "InkInput", targets: ["InkInput"]),
        .library(name: "InkSync", targets: ["InkSync"]),
        .library(name: "InkPersistence", targets: ["InkPersistence"]),
        .library(name: "InkUI", targets: ["InkUI"])
    ],
    targets: [
        // MARK: - Legacy (existing working code, migrating out incrementally)
        // Re-exports InkCore so existing call sites keep compiling unchanged.
        .target(
            name: "SpiderbrainKit",
            dependencies: ["InkCore"],
            path: "Sources/SpiderbrainKit"
        ),

        // MARK: - New Clean Architecture (empty for now)

        // Domain - Pure Swift, Foundation only
        .target(
            name: "InkCore",
            dependencies: [],
            path: "Sources/InkCore"
        ),

        // Feature modules - depend only on InkCore
        .target(
            name: "InkRendering",
            dependencies: ["InkCore"],
            path: "Sources/InkRendering"
        ),

        .target(
            name: "InkInput",
            dependencies: ["InkCore"],
            path: "Sources/InkInput"
        ),

        .target(
            name: "InkSync",
            dependencies: ["InkCore"],
            path: "Sources/InkSync"
        ),

        .target(
            name: "InkPersistence",
            dependencies: ["InkCore"],
            path: "Sources/InkPersistence"
        ),

        // Composition layer - depends on all features
        .target(
            name: "InkUI",
            dependencies: [
                "InkCore",
                "InkRendering",
                "InkInput",
                "InkSync",
                "InkPersistence"
            ],
            path: "Sources/InkUI"
        ),

        // MARK: - Tests
        .testTarget(
            name: "SpiderbrainKitTests",
            dependencies: ["SpiderbrainKit"]
        ),

        .testTarget(
            name: "InkCoreTests",
            dependencies: ["InkCore"]
        )
    ]
)
