// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SaturnCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SaturnCore", targets: ["SaturnCore"]),
        .executable(name: "saturnd", targets: ["saturnd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.0"),
    ],
    targets: [
        .target(
            name: "SaturnCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [.copy("Resources/Defaults"), .copy("Resources/Templates"), .copy("Resources/Lavish")]
        ),
        .executableTarget(
            name: "saturnd",
            dependencies: ["SaturnCore"]
        ),
        .testTarget(
            name: "SaturnCoreTests",
            dependencies: ["SaturnCore", "saturnd"]
        ),
    ]
)
