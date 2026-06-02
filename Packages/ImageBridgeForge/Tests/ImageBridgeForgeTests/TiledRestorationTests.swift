import Testing
import Foundation
import CoreVideo
import ForgeOptimizer
import FormatBridge
import ImageBridge
@testable import ImageBridgeForge

@Suite("ImageBridgeForge — print-res tiling through real NAFNet")
struct TiledRestorationTests {

    /// Runs only under xcodebuild + Metal; a NAFNet forward needs the staged metallib
    /// (ADR-0011), so it would crash under plain `swift test`. Opt in by touching the
    /// marker file `<repo-root>/.forge_run_mlx` before invoking xcodebuild (a fixed repo
    /// path survives the xcodebuild→xctest boundary that env vars / $TMPDIR don't).
    @Test("tiled NAFNet restores a large still: dims preserved, output sane (no OOM/garbage)")
    func tiledNAFNetSane() throws {
        // repo root: …/Packages/ImageBridgeForge/Tests/ImageBridgeForgeTests/<file>
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marker = repoRoot.appending(path: ".forge_run_mlx").path
        guard ProcessInfo.processInfo.environment["FORGE_RUN_MLX"] != nil
                || FileManager.default.fileExists(atPath: marker) else {
            print("[tiled-nafnet] no FORGE_RUN_MLX / .forge_run_mlx marker → skipping (needs xcodebuild + Metal)")
            return
        }
        guard let nafnet = try? NAFNetProcessor() else {
            print("[tiled-nafnet] NAFNet weights unavailable → skip"); return
        }

        let src = Self.gradient(512, 512)
        // Tiny budget forces the tiled path even on this modest buffer → several real
        // NAFNet tile-forwards run + feather-blend (256² tiles, 32 overlap).
        let tiled = TiledFrameProcessor(inner: nafnet, maxWholePixels: 200 * 200, tileSize: 256, overlap: 32)
        let out = tiled.process(src)

        #expect(CVPixelBufferGetWidth(out) == 512 && CVPixelBufferGetHeight(out) == 512, "scale-1 dims preserved")
        let (mIn, vIn) = Self.stats(src)
        let (mOut, vOut) = Self.stats(out)
        print("[tiled-nafnet] in mean=\(Int(mIn)) var=\(Int(vIn)) → out mean=\(Int(mOut)) var=\(Int(vOut))")
        // Catch the NaN→0 / garbage failure mode (the #40 fp16-overflow class): on clean
        // input NAFNet is ≈ near-identity, so brightness + detail must survive tiling.
        #expect(mOut > 8 && mOut < 247, "output not collapsed to black/white (mean \(mOut))")
        #expect(vOut > vIn * 0.25, "output keeps gradient detail (var \(vOut) vs \(vIn))")
        #expect(abs(mOut - mIn) < 40, "overall brightness roughly preserved")
    }

    // MARK: - helpers

    static func gradient(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< h { for x in 0 ..< w {
            let o = y * bpr + x * 4
            p[o] = UInt8((x * 255) / w); p[o + 1] = UInt8((y * 255) / h)
            p[o + 2] = UInt8(((x + y) * 255) / (w + h)); p[o + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    /// Mean + variance over B/G/R bytes.
    static func stats(_ pb: CVPixelBuffer) -> (mean: Double, variance: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, sumSq = 0.0
        let n = Double(w * h * 3)
        for y in 0 ..< h { for x in 0 ..< w { for c in 0 ..< 3 {
            let v = Double(p[y * bpr + x * 4 + c]); sum += v; sumSq += v * v
        } } }
        let mean = sum / n
        return (mean, sumSq / n - mean * mean)
    }
}
