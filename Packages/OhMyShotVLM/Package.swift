// swift-tools-version: 6.2
import PackageDescription

/// The pieces of Xcode's "approachable concurrency" plus explicit member imports, as in OhMyShotKit.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// The document model of the VLM pack (PaddleOCR-VL on MLX, Docs/ocr.md › The VLM pack), apart from OhMyShotKit so
// that only the text reader links MLX and the kit's own builds and tests never compile it. MLX's Metal kernels are
// compiled only by xcodebuild (SwiftPM can't), so `swift build` here checks the code but can't run it on the GPU.
let package = Package(
    name: "OhMyShotVLM",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OMSVLM", targets: ["OMSVLM"]),
    ],
    dependencies: [
        .package(path: "../OhMyShotKit"),
        // Exactly this version: the Swift port was checked against mlx-vlm 0.7.4 on MLX 0.32.3 (Docs/ocr.md › The VLM pack).
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
    ],
    targets: [
        .target(
            name: "OMSVLM",
            dependencies: [
                .product(name: "OMSPixels", package: "OhMyShotKit"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            swiftSettings: swiftSettings
        ),
        // Compares the Swift reading, stage by stage, with Tools/l3-spike/vlm_stages.py's.
        .executableTarget(
            name: "vlm-check",
            dependencies: ["OMSVLM", .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "OMSVLMTests",
            dependencies: ["OMSVLM"],
            swiftSettings: swiftSettings
        ),
    ]
)
