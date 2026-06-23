// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Strip",
    platforms: [.macOS(.v14)],
    targets: [
        // All app logic lives here so it can be unit-tested without the executable entry point.
        .target(
            name: "StripKit",
            path: "Sources/StripKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Thin entry point that boots the AppKit menu-bar agent.
        .executableTarget(
            name: "Strip",
            dependencies: ["StripKit"],
            path: "Sources/Strip",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StripKitTests",
            dependencies: ["StripKit"],
            path: "Tests/StripKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
