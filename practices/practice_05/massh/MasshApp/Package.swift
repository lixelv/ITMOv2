// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MasshApp",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "massh", targets: ["MasshApp"]),
        .library(name: "MasshUI", targets: ["MasshUI"]),
    ],
    dependencies: [
        .package(path: "../MasshCore"),
        // SwiftTerm 1.11.2 with a lower-latency redraw; see Vendor/SwiftTerm/PATCHES.md.
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        // Views and view models; SwiftUI Previews run here on MasshCore fakes.
        .target(name: "MasshUI", dependencies: ["MasshCore", "SwiftTerm"]),
        .executableTarget(name: "MasshApp", dependencies: ["MasshUI"]),
    ]
)
