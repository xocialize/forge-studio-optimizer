// swift-tools-version: 5.9
import PackageDescription

// ImageBridgeForge — the glue layer that injects ForgeOptimizer's learned scorers
// into ImageBridge's metric seam. It depends on BOTH (ImageBridge for the
// StillQualityScoring protocol, ForgeOptimizer for SigLIP2NRIQAScorer + MLX), which
// is exactly why it's a separate package: ImageBridge stays MLX-free, and
// ForgeOptimizer can't depend on ImageBridge (that would cycle). The runner uses
// this to get a SigLIP2 NR-IQA still scorer; the bridge never links MLX.
//
// Note: uses MLX → built/tested via xcodebuild for the runtime path (ADR-0011);
// `swift build` compiles it.
let package = Package(
    name: "ImageBridgeForge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImageBridgeForge", targets: ["ImageBridgeForge"])
    ],
    dependencies: [
        .package(name: "ImageBridge", path: "../ImageBridge"),
        .package(name: "ForgeOptimizer", path: "../ForgeOptimizer")
    ],
    targets: [
        .target(
            name: "ImageBridgeForge",
            dependencies: [
                .product(name: "ImageBridge", package: "ImageBridge"),
                .product(name: "ForgeOptimizer", package: "ForgeOptimizer")
            ]
        ),
        .testTarget(
            name: "ImageBridgeForgeTests",
            dependencies: ["ImageBridgeForge"]
        )
    ]
)
