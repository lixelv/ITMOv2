// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MasshCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MasshCore", targets: ["MasshCore"]),
    ],
    targets: [
        .target(name: "MasshCore"),
        .testTarget(name: "MasshCoreTests", dependencies: ["MasshCore"]),
    ]
)
