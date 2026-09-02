// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpiderbrainKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "SpiderbrainKit", targets: ["SpiderbrainKit"])
    ],
    targets: [
        .target(name: "SpiderbrainKit"),
        .testTarget(name: "SpiderbrainKitTests", dependencies: ["SpiderbrainKit"])
    ]
)
