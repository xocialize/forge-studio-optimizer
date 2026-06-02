import Testing
import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import ImageBridge

@Suite("ImageBridge AVIF output (native ImageIO, no vendoring)")
struct AVIFTests {

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("iba-avif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeGradientPNG(_ url: URL, w: Int = 256, h: Int = 192) throws {
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

    private func bytes(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    @Test("encode → AVIF natively, probe + decode round-trip, lossy < source PNG")
    func avifRoundTrip() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeGradientPNG(png)
        let (frames, meta) = try ImageBridgeFactory.makeDecoder().decode(url: png)

        let avif = dir.appendingPathComponent("out.avif")
        try ImageBridgeFactory.makeEncoder().encode(
            frames[0], settings: StillEncoderSettings(format: .avif, quality: 0.6), metadata: meta, to: avif)

        let m = try ImageBridgeFactory.makeProbe().probe(url: avif)
        print("[avif] \(m.width)x\(m.height) fmt=\(m.format) avif=\(bytes(avif))B png=\(bytes(png))B")
        #expect(m.format == .avif, "probe identifies AVIF, got \(m.format)")
        #expect(m.width == 256 && m.height == 192)
        #expect(bytes(avif) > 0)
        #expect(bytes(avif) < bytes(png), "lossy AVIF should beat the lossless PNG source")

        // Decodes back to the right shape (the pixels survived a real codec round-trip).
        let (rt, _) = try ImageBridgeFactory.makeDecoder().decode(url: avif)
        #expect(CVPixelBufferGetWidth(rt[0]) == 256 && CVPixelBufferGetHeight(rt[0]) == 192)
    }

    @Test("quality-target search drives the AVIF knob")
    func avifQualityTarget() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeGradientPNG(png)
        let (frames, meta) = try ImageBridgeFactory.makeDecoder().decode(url: png)

        let search = StillQualityTargetSearch(targetScore: 38.0, qualityRange: 0.3 ... 1.0, slack: 0.5, maxProbes: 8)
        let enc = ImageBridgeFactory.makeQualityTargetEncoder(scorer: PSNRScorer(), search: search)
        let out = dir.appendingPathComponent("out.avif")
        let r = try enc.encode(original: frames[0], format: .avif, metadata: meta, to: out)

        print("[avif] target q=\(String(format: "%.3f", r.quality)) PSNR=\(String(format: "%.1f", r.achievedScore)) bytes=\(r.bytes)")
        #expect(r.metTarget && r.quality < 1.0 && r.bytes > 0)
    }
}

/// Full-reference PSNR stand-in (same as the other quality-target tests).
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
