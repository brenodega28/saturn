// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SaturnUI",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "SaturnUI", targets: ["SaturnUI"]),
    ],
    targets: [
        .target(name: "SaturnUI"),
        .testTarget(name: "SaturnUITests", dependencies: ["SaturnUI"]),
    ]
)
