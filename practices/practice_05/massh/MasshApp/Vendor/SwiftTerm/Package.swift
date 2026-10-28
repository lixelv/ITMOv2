// swift-tools-version:5.9
// SwiftTerm 1.11.2 (MIT, https://github.com/migueldeicaza/SwiftTerm), vendored for massh with one change:
// the screen is redrawn right away after a quiet period instead of always 1/60 s later (see PATCHES.md).
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: ["Mac/README.md"]),
    ],
    swiftLanguageVersions: [.v5]
)
