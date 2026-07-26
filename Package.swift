// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Parallax",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Parallax", targets: ["Parallax"])
    ],
    targets: [
        .executableTarget(
            name: "Parallax",
            path: "Sources/Parallax",
            resources: [
                .copy("Resources")
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
