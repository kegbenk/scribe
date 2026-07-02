// swift-tools-version: 5.9

// Dev manifest: library + scribe-cli + tests. Used for local development,
// eval/regenerate.js, and CI. SPM consumers resolve the root Package.swift
// instead, which exposes the library only (no argument-parser dependency).
// Keep target definitions in sync between the two manifests.

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
