// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SignalKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SignalKit",
            targets: ["SignalKit"]
        )
    ],
    targets: [
        .target(
            name: "SignalKit",
            dependencies: []
        ),
        .executableTarget(
            name: "SignalKitCLI",
            dependencies: ["SignalKit"]
        ),
        .testTarget(
            name: "SignalKitTests",
            dependencies: ["SignalKit"]
        ),
        .executableTarget(
            name: "Benchmarks",
            dependencies: ["SignalKit"],
            path: "Benchmarks",
            exclude: ["baseline.json", "latest.json"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
