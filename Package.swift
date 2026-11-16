// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhoneBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PhoneBridgeCore"),
        .executableTarget(
            name: "PhoneBridge",
            dependencies: ["PhoneBridgeCore"]
        ),
        .testTarget(
            name: "PhoneBridgeCoreTests",
            dependencies: ["PhoneBridgeCore"]
        ),
    ]
)
