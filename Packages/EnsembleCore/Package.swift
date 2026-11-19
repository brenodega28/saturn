// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EnsembleCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EnsembleCore", targets: ["EnsembleCore"]),
        .executable(name: "ensembled", targets: ["ensembled"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.0"),
    ],
    targets: [
        .target(
            name: "EnsembleCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [.copy("Resources/Defaults"), .copy("Resources/Templates"), .copy("Resources/Lavish")]
        ),
        .executableTarget(
            name: "ensembled",
            dependencies: ["EnsembleCore"]
        ),
        .testTarget(
            name: "EnsembleCoreTests",
            dependencies: ["EnsembleCore", "ensembled"]
        ),
    ]
)
