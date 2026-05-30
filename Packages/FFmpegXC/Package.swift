// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FFmpegXC",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FFmpegXC", targets: ["FFmpegXC"])
    ],
    targets: [
        .target(
            name: "FFmpegXC",
            path: "Sources/FFmpegXC",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/Sources/FFmpegXC/lib",
                ]),
                .linkedLibrary("avformat"),
                .linkedLibrary("avcodec"),
                .linkedLibrary("avutil"),
                .linkedLibrary("swscale"),
                .linkedLibrary("swresample"),
                .linkedLibrary("dav1d"),
                .linkedLibrary("vpx"),
                .linkedLibrary("opus"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("lzma"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
