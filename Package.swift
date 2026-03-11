// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "macOSdb",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "macOSdbKit", targets: ["macOSdbKit"]),
        .executable(name: "macosdb", targets: ["macosdb"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "macOSdbKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "macosdb",
            dependencies: [
                "macOSdbKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "macOSdbKitTests",
            dependencies: ["macOSdbKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
