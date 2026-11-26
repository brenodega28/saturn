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
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "SaturnCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            resources: [.copy("Resources/Defaults"), .copy("Resources/Templates"), .copy("Resources/Lavish"), .copy("Resources/Onboarding"), .copy("Resources/Remote")]
        ),
        .executableTarget(
            name: "saturnd",
            dependencies: ["SaturnCore"]
        ),
        .testTarget(
            name: "SaturnCoreTests",
            dependencies: [
                "SaturnCore", "saturnd",
                .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
            ]
        ),
    ]
)
