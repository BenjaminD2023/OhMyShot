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
        .library(name: "OMSCapture", targets: ["OMSCapture"]),
        .library(name: "OMSUI", targets: ["OMSUI"]),
        .library(name: "OMSOCR", targets: ["OMSOCR"]),
        .library(name: "OMSAnnotate", targets: ["OMSAnnotate"]),
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
        // ScreenCaptureKit, the selection overlay, window catalog, selection model. Main-actor by default.
        .target(
            name: "OMSCapture",
            dependencies: ["OMSCore"],
            swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]
        ),
        // Menu bar, settings, onboarding, shortcuts, the OCR panel. Main-actor by default.
        .target(
            name: "OMSUI",
            dependencies: ["OMSCore", "OMSOCR", "KeyboardShortcuts"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]
        ),
        // Text recognition engines and what turns their output into text. Pure computation: not tied to
        // the main actor, so recognition and post-processing never block the UI.
        .target(
            name: "OMSOCR",
            swiftSettings: swiftSettings
        ),
        // The annotation canvas the editor and in-place annotation share. Main-actor by default; the
        // document and its renderer are nonisolated, so exports render off the main actor.
        .target(
            name: "OMSAnnotate",
            dependencies: ["OMSCore"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "OMSCoreTests",
            dependencies: ["OMSCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "OMSOCRTests",
            dependencies: ["OMSOCR"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "OMSAnnotateTests",
            dependencies: ["OMSAnnotate"],
            swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "OMSCaptureTests",
            dependencies: ["OMSCapture"],
            swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "OMSUITests",
            dependencies: ["OMSUI"],
            swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]
        ),
    ]
)
