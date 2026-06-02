// swift-tools-version: 5.9
import PackageDescription

// COxipng — C-ABI shim over the oxipng Rust crate (lossless PNG optimization, MIT)
// for ImageBridge Phase 2. Mirrors the FFmpegXC vendoring pattern: the static lib
// (liboxipng_shim.a) is built locally via build.sh (gitignored); only the header +
// this wrapper are committed.
let package = Package(
    name: "Oxipng",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "COxipng", targets: ["COxipng"])
    ],
    targets: [
        .target(
            name: "COxipng",
            path: "Sources/COxipng",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/Sources/COxipng/lib",
                ]),
                .linkedLibrary("oxipng_shim"),
                // Rust staticlib's runtime needs on macOS.
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
