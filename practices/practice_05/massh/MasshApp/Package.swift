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
        // 1.12+ needs the separately downloaded Metal toolchain to build.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),
    ],
    targets: [
        // Views and view models; SwiftUI Previews run here on MasshCore fakes.
        .target(name: "MasshUI", dependencies: ["MasshCore", "SwiftTerm"]),
        .executableTarget(name: "MasshApp", dependencies: ["MasshUI"]),
    ]
)
