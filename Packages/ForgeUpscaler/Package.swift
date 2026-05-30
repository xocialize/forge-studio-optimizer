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
                // Per-file .copy (NOT .copy("Resources")) so each lands at the
                // bundle resource ROOT — the code resolves them via
                // Bundle.module.url(forResource:withExtension:) with no
                // subdirectory. .copy("Resources") nests them under
                // Resources/Resources/ (esp. under xcodebuild's bundle layout),
                // breaking every lookup. .process() is avoided because it
                // compiles/mangles the .mlpackage directories.
                .copy("Resources/efrlfn_x2.safetensors"),
                .copy("Resources/efrlfn_x4.safetensors"),
                .copy("Resources/realesr_anime_x4.safetensors"),
                .copy("Resources/realesr_general_wdn_x4.safetensors"),
                .copy("Resources/realesr_general_x4.safetensors"),
                .copy("Resources/realesrgan_x2.mlpackage"),
                .copy("Resources/realesrgan_x4.mlpackage"),
                .copy("Resources/MODELS.md"),
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
