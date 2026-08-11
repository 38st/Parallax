// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Parallax",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Parallax", targets: ["Parallax"]),
        .library(name: "RelayCore", targets: ["RelayCore"]),
        .library(name: "RelayEngine", targets: ["RelayEngine"]),
    ],
    targets: [
        .target(
            name: "RelayCore",
            path: "Sources/RelayCore"
        ),
        .target(
            name: "RelayEngine",
            dependencies: ["RelayCore"],
            path: "Sources/RelayEngine"
        ),
        .executableTarget(
            name: "Parallax",
            dependencies: ["RelayCore", "RelayEngine"],
            path: "Sources/Parallax",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ParallaxTests",
            dependencies: ["Parallax", "RelayCore", "RelayEngine"],
            path: "Tests/ParallaxTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "RelayCoreTests",
            dependencies: ["RelayCore"],
            path: "Tests/RelayCoreTests"
        ),
        .testTarget(
            name: "RelayEngineTests",
            dependencies: ["RelayCore", "RelayEngine"],
            path: "Tests/RelayEngineTests"
        )
    ]
)
