// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "Scribe",
            targets: ["Scribe"]
        ),
        .executable(
            name: "scribe-cli",
            targets: ["ScribeCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "Scribe",
            path: "Sources/Scribe"
        ),
        .executableTarget(
            name: "ScribeCLI",
            dependencies: [
                "Scribe",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ScribeCLI"
        ),
        .testTarget(
            name: "ScribeTests",
            dependencies: ["Scribe"],
            path: "Tests/ScribeTests"
        ),
    ]
)
