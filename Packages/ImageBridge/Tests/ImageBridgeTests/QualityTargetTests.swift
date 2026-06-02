import Testing
import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import ImageBridge

@Suite("ImageBridge quality-target search (Phase 2)")
struct QualityTargetTests {

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("ibq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A gradient PNG — JPEG quality is then discriminative (flat fills are too easy).
    private func makeGradientPNG(_ url: URL, w: Int = 192, h: Int = 144) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let grad = CGGradient(colorsSpace: cs,
                              colors: [CGColor(red: 0.95, green: 0.1, blue: 0.2, alpha: 1),
                                       CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test("binary search picks the lowest JPEG quality that clears the floor")
    func search() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeGradientPNG(png)
        let (frames, meta) = try ImageBridgeFactory.makeDecoder().decode(url: png)
        let original = frames[0]

        let scorer = PSNRScorer()                  // full-ref PSNR (stand-in for SSIMULACRA2)
        let search = StillQualityTargetSearch(targetScore: 40.0, qualityRange: 0.3 ... 1.0,
                                              slack: 0.5, maxProbes: 8)
        let enc = ImageBridgeFactory.makeQualityTargetEncoder(scorer: scorer, search: search)

        let out = dir.appendingPathComponent("out.jpg")
        let result = try enc.encode(original: original, format: .jpeg, metadata: meta, to: out)

        print("[sqt] chosen q=\(String(format: "%.3f", result.quality)) PSNR=\(String(format: "%.2f", result.achievedScore)) "
            + "bytes=\(result.bytes) probes=\(result.probeCount) met=\(result.metTarget)")
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(result.metTarget)                  // the floor is reachable on this image
        #expect(result.achievedScore >= 40.0 - 0.5)
        #expect(result.probeCount >= 1)
        // The chosen quality should be BELOW the max — i.e. the search saved bits,
        // not just shipped quality 1.0.
        #expect(result.quality < 1.0)
    }
}

/// Full-reference PSNR over two BGRA `CVPixelBuffer`s (a deterministic stand-in
/// for SSIMULACRA2 in tests; the real metric injects identically).
private struct PSNRScorer: StillQualityScoring, @unchecked Sendable {
    func score(reference: CVPixelBuffer, distorted: CVPixelBuffer) -> Double {
        func lock(_ b: CVPixelBuffer) { CVPixelBufferLockBaseAddress(b, .readOnly) }
        func unlock(_ b: CVPixelBuffer) { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        lock(reference); lock(distorted)
        defer { unlock(reference); unlock(distorted) }
        let w = min(CVPixelBufferGetWidth(reference), CVPixelBufferGetWidth(distorted))
        let h = min(CVPixelBufferGetHeight(reference), CVPixelBufferGetHeight(distorted))
        guard let rb = CVPixelBufferGetBaseAddress(reference),
              let db = CVPixelBufferGetBaseAddress(distorted) else { return 0 }
        let rStride = CVPixelBufferGetBytesPerRow(reference)
        let dStride = CVPixelBufferGetBytesPerRow(distorted)
        let rp = rb.assumingMemoryBound(to: UInt8.self)
        let dp = db.assumingMemoryBound(to: UInt8.self)
        var sse = 0.0, n = 0.0
        var y = 0
        while y < h {
            var x = 0
            while x < w * 4 {                       // BGRA bytes
                let d = Double(rp[y * rStride + x]) - Double(dp[y * dStride + x])
                sse += d * d; n += 1
                x += 1
            }
            y += 1
        }
        guard n > 0 else { return 0 }
        let mse = sse / n
        return mse <= 0 ? 99.0 : min(99.0, 10.0 * log10(255.0 * 255.0 / mse))
    }
}
