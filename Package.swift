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
    ],
    targets: [
        .executableTarget(
            name: "Parallax",
            path: "Sources/Parallax",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ParallaxTests",
            dependencies: ["Parallax"],
            path: "Tests/ParallaxTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
