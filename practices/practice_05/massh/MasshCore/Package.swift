// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MasshCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MasshCore", targets: ["MasshCore"]),
    ],
    targets: [
        .target(name: "MasshCore", resources: [.process("Resources")]),
        .testTarget(name: "MasshCoreTests", dependencies: ["MasshCore"], exclude: ["Fixtures"]),
    ]
)
