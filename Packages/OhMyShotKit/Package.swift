// swift-tools-version: 6.2
import PackageDescription

/// The pieces of Xcode's "approachable concurrency" plus explicit member imports, for every target.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "OhMyShotKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OMSCore", targets: ["OMSCore"]),
        .library(name: "OMSUI", targets: ["OMSUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", .upToNextMinor(from: "3.1.0")),
    ],
    targets: [
        // Models, geometry, settings, permissions, automation. No UI framework state; UI-facing
        // types opt into the main actor explicitly.
        .target(
            name: "OMSCore",
            swiftSettings: swiftSettings
        ),
        // Menu bar, settings, onboarding, shortcuts. Main-actor by default.
        .target(
            name: "OMSUI",
            dependencies: ["OMSCore", "KeyboardShortcuts"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "OMSCoreTests",
            dependencies: ["OMSCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
