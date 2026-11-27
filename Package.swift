// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OpenCull",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenCull", targets: ["OpenCull"]),
        .executable(name: "opencull-cli", targets: ["OpenCullCLI"]),
        .library(name: "CullCore", targets: ["CullCore"]),
    ],
    targets: [
        // All analysis, grouping, scoring and export logic. No UI, fully testable.
        .target(name: "CullCore"),
        // The SwiftUI macOS app.
        .executableTarget(name: "OpenCull", dependencies: ["CullCore"]),
        // Command-line tool: analyze a folder and print the results.
        .executableTarget(name: "OpenCullCLI", dependencies: ["CullCore"]),
        .testTarget(name: "CullCoreTests", dependencies: ["CullCore"]),
        .testTarget(name: "OpenCullTests", dependencies: ["OpenCull", "CullCore"]),
    ]
)
