// swift-tools-version: 6.2
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
    dependencies: [
        .package(url: "https://github.com/realtime-sanitizer/RTSanStandaloneSwift", .upToNextMajor(from: "0.1.0"))
    ],
    targets: [
        .target(
            name: "SignalKit",
            dependencies: [
                .product(name: "RealtimeSanitizer", package: "RTSanStandaloneSwift")
            ],
            swiftSettings: [.define("RELEASE", .when(configuration: .release))]
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
            dependencies: [
                "SignalKit",
                .product(name: "RealtimeSanitizer", package: "RTSanStandaloneSwift")
            ],
            path: "Benchmarks",
            exclude: ["baseline.json", "latest.json"],
            swiftSettings: [.define("RELEASE", .when(configuration: .release))]
        )
    ],
    swiftLanguageModes: [.v5]
)
