// swift-tools-version: 5.9

// Published manifest: what SPM consumers (rsvp-reader, velo-macos) resolve.
// Library only — no CLI, no third-party dependencies. The scribe-cli tool and
// its swift-argument-parser dependency live in the dev manifest at
// swift/Package.swift so library consumers never pull them.

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
            path: "swift/Sources/Scribe"
        ),
        .testTarget(
            name: "ScribeTests",
            dependencies: ["Scribe"],
            path: "swift/Tests/ScribeTests"
        ),
    ]
)
