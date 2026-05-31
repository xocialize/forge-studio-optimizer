// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ForgeOptimizer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ForgeOptimizer", targets: ["ForgeOptimizer"]),
        .executable(name: "forge-benchmark-runner", targets: ["forge-benchmark-runner"]),
        .executable(name: "forge-gate-checker", targets: ["forge-gate-checker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", "0.31.2" ..< "0.32.0"),
        .package(name: "FormatBridge", path: "../FormatBridge"),
        .package(name: "ForgeUpscaler", path: "../ForgeUpscaler"),
    ],
    targets: [
        .target(
            name: "ForgeOptimizer",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "FormatBridge", package: "FormatBridge"),
                .product(name: "ForgeUpscaler", package: "ForgeUpscaler"),
            ],
            exclude: [
                "Benchmark/README.md",
            ],
            resources: [
                // Per-file .copy (NOT .copy("Resources")) so each lands at the
                // bundle resource ROOT, where CoreMLProcessor / NAFNetProcessor
                // resolve them via Bundle.module.url(forResource:). See ADR-0011
                // (.copy("Resources") double-nests under Resources/Resources/;
                // .process() would mangle the .mlpackage directories).
                .copy("Resources/arcnn.mlpackage"),
                .copy("Resources/dncnn_color.mlpackage"),
                .copy("Resources/dncnn_gray.mlpackage"),
                .copy("Resources/espcn_x2.mlpackage"),
                .copy("Resources/espcn_x4.mlpackage"),
                .copy("Resources/quality_regressor.mlpackage"),
                .copy("Resources/nafnet.safetensors"),
                .copy("Resources/MODELS.md"),
            ],
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "forge-benchmark-runner",
            dependencies: ["ForgeOptimizer"],
            path: "Sources/forge-benchmark-runner"
        ),
        .executableTarget(
            name: "forge-gate-checker",
            dependencies: ["ForgeOptimizer"],
            path: "Sources/forge-gate-checker"
        ),
        .testTarget(
            name: "ForgeOptimizerTests",
            dependencies: ["ForgeOptimizer"]
        ),
    ]
)
