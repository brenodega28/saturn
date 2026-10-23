// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EnsembleCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EnsembleCore", targets: ["EnsembleCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
    ],
    targets: [
        .target(
            name: "EnsembleCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "EnsembleCoreTests",
            dependencies: ["EnsembleCore"]
        ),
    ]
)
