// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnapToolMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SnapTool", targets: ["SnapTool"])],
    targets: [
        .target(name: "SnapCore"),
        .executableTarget(name: "SnapTool", dependencies: ["SnapCore"]),
        .testTarget(name: "SnapCoreTests", dependencies: ["SnapCore"]),
        .testTarget(name: "SnapToolSettingsTests", dependencies: ["SnapTool"])
    ],
    swiftLanguageVersions: [.v5]
)
