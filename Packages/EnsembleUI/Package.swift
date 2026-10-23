// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EnsembleUI",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "EnsembleUI", targets: ["EnsembleUI"]),
    ],
    targets: [
        .target(name: "EnsembleUI"),
    ]
)
