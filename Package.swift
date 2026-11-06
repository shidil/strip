// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Strip",
    platforms: [.macOS(.v14)],
    targets: [
        // The pure core: model, geometry and policies. No AppKit, no AX, no os (ADR-0006).
        // StripCore must not import StripKit; StripKit depends on StripCore and re-exports it.
        .target(
            name: "StripCore",
            path: "Sources/StripCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The platform layer and app logic, unit-testable without the executable entry point.
        .target(
            name: "StripKit",
            dependencies: ["StripCore"],
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
            name: "StripCoreTests",
            dependencies: ["StripCore"],
            path: "Tests/StripCoreTests",
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
