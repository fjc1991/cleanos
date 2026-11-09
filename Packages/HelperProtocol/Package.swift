// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelperProtocol",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HelperProtocol", targets: ["HelperProtocol"])],
    targets: [
        .target(name: "HelperProtocol"),
        .testTarget(name: "HelperProtocolTests", dependencies: ["HelperProtocol"]),
    ],
    swiftLanguageModes: [.v6]
)
