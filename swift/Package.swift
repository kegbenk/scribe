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
    ],
    targets: [
        .target(
            name: "Scribe",
            path: "Sources/Scribe"
        ),
        .testTarget(
            name: "ScribeTests",
            dependencies: ["Scribe"],
            path: "Tests/ScribeTests"
        ),
    ]
)
