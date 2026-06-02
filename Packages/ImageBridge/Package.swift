// swift-tools-version: 5.9
import PackageDescription

// ImageBridge — static-image conversion + optimization, sibling to FormatBridge
// (ImageBridge-PRD-v0.1 / ADR-0019). A still is a one-frame CVPixelBuffer, so
// ForgeOptimizer's `FrameProcessor` AI chain is reused UNCHANGED; ImageBridge is
// the I/O boundary (ImageIO/PDFKit) + a still analog of QualityTargetSearch.
//
// Phase 1 (this scaffold): native ImageIO decode/encode + orchestrator with
// FrameProcessor passthrough. Only FormatBridge is needed (for `FrameProcessor`
// + the shared enums) — no MLX, so it builds under `swift build`. The
// ForgeOptimizer/ForgeUpscaler deps (real models + tiling) land when the AI
// chain is wired (Phase 1.b+).
let package = Package(
    name: "ImageBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImageBridge", targets: ["ImageBridge"])
    ],
    dependencies: [
        .package(name: "FormatBridge", path: "../FormatBridge"),
        .package(name: "Oxipng", path: "../Oxipng")
    ],
    targets: [
        .target(
            name: "ImageBridge",
            dependencies: [
                .product(name: "FormatBridge", package: "FormatBridge"),
                .product(name: "COxipng", package: "Oxipng")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "ImageBridgeTests",
            dependencies: ["ImageBridge"]
        )
    ]
)
