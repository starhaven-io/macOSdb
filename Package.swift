// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macOSdb",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "macosdb", targets: ["macosdb"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "macOSdbCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "macosdb",
            dependencies: [
                "macOSdbCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "macOSdbCoreTests",
            dependencies: [
                "macOSdbCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "macosdbTests",
            dependencies: ["macosdb"]
        ),
    ]
)
