// swift-tools-version: 6.2
//
// Builds the app's pure logic (AI Usage Viewer/Core) as a library so it
// can be unit-tested with `swift test` / `make test`. The Xcode project
// compiles the same files directly into the app.

import PackageDescription

let package = Package(
    name: "UsageCore",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "UsageCore",
            path: "AI Usage Viewer/Core"
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
