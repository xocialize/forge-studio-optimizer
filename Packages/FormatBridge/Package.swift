// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FormatBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FormatBridge", targets: ["FormatBridge"])
    ],
    dependencies: [
        .package(name: "FFmpegXC", path: "../FFmpegXC")
    ],
    targets: [
        .target(
            name: "FormatBridge",
            dependencies: [
                .product(name: "FFmpegXC", package: "FFmpegXC")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .testTarget(
            name: "FormatBridgeTests",
            dependencies: ["FormatBridge"],
            resources: [.copy("Fixtures")]
        )
    ]
)
