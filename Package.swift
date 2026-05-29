// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "JLISwift",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "JLISwift",
            targets: ["JLISwift"]
        ),
        .library(
            name: "JLIDICOM",
            targets: ["JLIDICOM"]
        ),
        .executable(
            name: "JLIBench",
            targets: ["JLIBench"]
        ),
    ],
    targets: [
        .target(
            name: "JLISwift"
        ),
        .target(
            name: "JLIDICOM"
        ),
        .executableTarget(
            name: "JLIBench",
            dependencies: ["JLISwift", "JLIDICOM"]
        ),
        .testTarget(
            name: "JLISwiftTests",
            dependencies: ["JLISwift", "JLIDICOM"]
        ),
    ]
)
