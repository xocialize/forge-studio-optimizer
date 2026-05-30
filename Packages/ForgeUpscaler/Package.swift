// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ForgeUpscaler",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ForgeUpscaler", targets: ["ForgeUpscaler"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", "0.31.2" ..< "0.32.0"),
        .package(name: "FormatBridge", path: "../FormatBridge"),
    ],
    targets: [
        .target(
            name: "ForgeUpscaler",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "FormatBridge", package: "FormatBridge"),
            ],
            resources: [
                .copy("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalFX"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(
            name: "ForgeUpscalerTests",
            dependencies: ["ForgeUpscaler"]
        ),
    ]
)
