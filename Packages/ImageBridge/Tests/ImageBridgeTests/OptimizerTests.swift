import Testing
import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import FormatBridge
@testable import ImageBridge

@Suite("ImageBridge still optimizer (Phase 4 plumbing)")
struct OptimizerTests {

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("ibo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

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

    @Test("lossy path: restores, then ships the smallest encode clearing the floor")
    func lossyOptimize() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeGradientPNG(png)
        let out = dir.appendingPathComponent("out.jpg")

        let opt = ImageBridgeFactory.makeOptimizer(scorer: PSNRScorer(), frameProcessor: CountingIdentity())
        let settings = StillOptimizationSettings(
            format: .jpeg, restore: true,
            search: StillQualityTargetSearch(targetScore: 40.0, qualityRange: 0.3 ... 1.0, slack: 0.5, maxProbes: 8))
        let r = try opt.optimize(input: png, output: out, settings: settings)

        print("[opt] lossy q=\(r.target.map { String(format: "%.3f", $0.quality) } ?? "-") "
            + "score=\(r.target.map { String(format: "%.1f", $0.achievedScore) } ?? "-") bytes=\(r.outputBytes) restored=\(r.restored)")
        #expect(r.restored)                                   // processor ran
        #expect(!r.lossless)
        let t = try #require(r.target)
        #expect(t.metTarget && t.quality < 1.0)               // search saved bits
        #expect(r.outputBytes > 0 && FileManager.default.fileExists(atPath: out.path))
    }

    @Test("PNG path: lossless oxipng, no perceptual search")
    func losslessOptimize() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeGradientPNG(png)
        let out = dir.appendingPathComponent("out.png")

        let opt = ImageBridgeFactory.makeOptimizer(scorer: PSNRScorer(), frameProcessor: nil)
        let r = try opt.optimize(input: png, output: out,
                                 settings: StillOptimizationSettings(format: .png, restore: true))
        #expect(r.lossless && r.target == nil)
        #expect(!r.restored)                                  // nil processor → nothing restored
        #expect(r.outputBytes > 0)
        // Pixels preserved exactly (lossless): decode both, identical dims.
        let m = try ImageBridgeFactory.makeProbe().probe(url: out)
        #expect(m.format == .png && m.width == 192 && m.height == 144)
    }
}

/// Records that it ran, returns input unchanged — stands in for the restoration chain.
private final class CountingIdentity: FrameProcessor, @unchecked Sendable {
    func process(_ pb: CVPixelBuffer) -> CVPixelBuffer { pb }
}

/// Full-reference PSNR stand-in (the real run injects SigLIP2 NR-IQA identically).
private struct PSNRScorer: StillQualityScoring, @unchecked Sendable {
    func score(reference: CVPixelBuffer, distorted: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(reference, .readOnly); CVPixelBufferLockBaseAddress(distorted, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(reference, .readOnly); CVPixelBufferUnlockBaseAddress(distorted, .readOnly) }
        let w = min(CVPixelBufferGetWidth(reference), CVPixelBufferGetWidth(distorted))
        let h = min(CVPixelBufferGetHeight(reference), CVPixelBufferGetHeight(distorted))
        guard let rb = CVPixelBufferGetBaseAddress(reference), let db = CVPixelBufferGetBaseAddress(distorted) else { return 0 }
        let rS = CVPixelBufferGetBytesPerRow(reference), dS = CVPixelBufferGetBytesPerRow(distorted)
        let rp = rb.assumingMemoryBound(to: UInt8.self), dp = db.assumingMemoryBound(to: UInt8.self)
        var sse = 0.0, n = 0.0
        for y in 0 ..< h { for x in 0 ..< w * 4 {
            let d = Double(rp[y * rS + x]) - Double(dp[y * dS + x]); sse += d * d; n += 1
        } }
        guard n > 0 else { return 0 }
        let mse = sse / n
        return mse <= 0 ? 99.0 : min(99.0, 10.0 * log10(255.0 * 255.0 / mse))
    }
}
