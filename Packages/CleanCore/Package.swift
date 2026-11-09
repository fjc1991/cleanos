// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CleanCore", targets: ["CleanCore"])],
    dependencies: [.package(path: "../HelperProtocol")],
    targets: [
        .target(name: "CleanCore", dependencies: [.product(name: "HelperProtocol", package: "HelperProtocol")], resources: [.copy("Resources")]),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore"]),
    ],
    swiftLanguageModes: [.v6]
)
