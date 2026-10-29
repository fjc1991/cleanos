// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UpdateSources",
    platforms: [.macOS(.v14)],
    products: [.library(name: "UpdateSources", targets: ["UpdateSources"])],
    targets: [
        .target(name: "UpdateSources"),
        .testTarget(name: "UpdateSourcesTests", dependencies: ["UpdateSources"]),
    ],
    swiftLanguageModes: [.v6]
)
