import Testing
import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import FormatBridge
@testable import ImageBridge

@Suite("ImageBridge alpha split/recombine (Phase 3)")
struct AlphaTests {

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("iba-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A PNG with real transparency: a half-alpha (≈128) cyan fill on a clear canvas.
    private func makeTranslucentPNG(_ url: URL, w: Int = 48, h: Int = 32, alpha: CGFloat = 0.5) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))             // start fully transparent
        ctx.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.9, alpha: alpha))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// Mean alpha of a decoded (premultiplied BGRA) buffer.
    private func meanAlpha(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for y in 0 ..< h { for x in 0 ..< w { sum += Double(p[y * stride + x * 4 + 3]) } }
        return sum / Double(w * h)
    }

    @Test("source has alpha; split/recombine round-trips it through a processor")
    func alphaPreserved() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeTranslucentPNG(png, alpha: 0.5)

        // Probe sees alpha; decoded buffer carries ~128 alpha.
        let m = try ImageBridgeFactory.makeProbe().probe(url: png)
        #expect(m.alpha != .none)
        let (inFrames, _) = try ImageBridgeFactory.makeDecoder().decode(url: png)
        let inAlpha = meanAlpha(inFrames[0])
        #expect(abs(inAlpha - 128) < 12, "decoded input alpha ~128, got \(inAlpha)")

        // Run through the orchestrator WITH a processor → triggers split/recombine
        // (the model sees opaque RGB; alpha is recombined after).
        let out = dir.appendingPathComponent("out.png")
        try ImageBridgeFactory.makeOrchestrator().convert(
            input: png, output: out, settings: StillEncoderSettings(format: .png),
            frameProcessor: IdentityProcessor())

        let (outFrames, mOut) = try ImageBridgeFactory.makeDecoder().decode(url: out)
        #expect(mOut.alpha != .none, "alpha must survive the round-trip")
        let outAlpha = meanAlpha(outFrames[0])
        print("[alpha] in≈\(Int(inAlpha)) → out≈\(Int(outAlpha))")
        #expect(abs(outAlpha - inAlpha) < 6, "alpha preserved through split/recombine (in \(inAlpha) vs out \(outAlpha))")
    }

    @Test("opaque source skips the alpha path (no regression)")
    func opaqueUnaffected() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeTranslucentPNG(png, alpha: 1.0)  // fully opaque
        let out = dir.appendingPathComponent("out.png")
        try ImageBridgeFactory.makeOrchestrator().convert(
            input: png, output: out, settings: StillEncoderSettings(format: .png),
            frameProcessor: IdentityProcessor())
        let m = try ImageBridgeFactory.makeProbe().probe(url: out)
        #expect(m.width == 48 && m.height == 32)
    }
}

/// No-op processor that also exercises the split path (real ForgeOptimizer chains
/// drop in identically — they see only the opaque RGB buffer).
private struct IdentityProcessor: FrameProcessor, @unchecked Sendable {
    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer { pixelBuffer }
}
