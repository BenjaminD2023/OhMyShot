// swift-tools-version: 6.2
import PackageDescription

// The OCR benchmark: renders test images with exact ground truth and scores OhMyShot's OCR engines on
// them. Run it with `swift run -c release --package-path Tools/ocr-bench ocr-bench`.
let package = Package(
    name: "ocr-bench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/OhMyShotKit"),
    ],
    targets: [
        .executableTarget(
            name: "ocr-bench",
            dependencies: [.product(name: "OMSOCR", package: "OhMyShotKit")],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ]
)
