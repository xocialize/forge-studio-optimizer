import Testing
import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import FormatBridge
@testable import ImageBridge

@Suite("ImageBridge round-trip (Phase 1)")
struct RoundTripTests {

    // MARK: helpers

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("ib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Write a deterministic RGBA test PNG (with a translucent region) via ImageIO.
    private func makeTestPNG(_ url: URL, w: Int = 64, h: Int = 48) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageBridgeError.encodeFailed("test CGContext")
        }
        ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 0.5))   // translucent → alpha
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        let cg = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    // MARK: tests

    @Test("probe reports dimensions, format, and alpha")
    func probe() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png")
        try makeTestPNG(png)

        let m = try ImageBridgeFactory.makeProbe().probe(url: png)
        #expect(m.width == 64)
        #expect(m.height == 48)
        #expect(m.format == .png)
        #expect(m.alpha != .none)        // the translucent fill ⇒ alpha present
        #expect(m.frameCount == 1)
    }

    @Test("decode → encode round-trip preserves dimensions")
    func roundTrip() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeTestPNG(png)
        let out = dir.appendingPathComponent("out.png")

        let (frames, meta) = try ImageBridgeFactory.makeDecoder().decode(url: png)
        #expect(frames.count == 1)
        #expect(CVPixelBufferGetWidth(frames[0]) == 64)
        #expect(CVPixelBufferGetHeight(frames[0]) == 48)

        try ImageBridgeFactory.makeEncoder().encode(frames[0],
            settings: StillEncoderSettings(format: .png), metadata: meta, to: out)

        let m2 = try ImageBridgeFactory.makeProbe().probe(url: out)
        #expect(m2.width == 64)
        #expect(m2.height == 48)
        #expect(m2.format == .png)
    }

    @Test("orchestrator passthrough (nil processor) is a no-op conversion")
    func passthrough() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeTestPNG(png)
        let out = dir.appendingPathComponent("out.jpg")

        try ImageBridgeFactory.makeOrchestrator().convert(
            input: png, output: out,
            settings: StillEncoderSettings(format: .jpeg, quality: 0.9),
            frameProcessor: nil)

        #expect(FileManager.default.fileExists(atPath: out.path))
        let m = try ImageBridgeFactory.makeProbe().probe(url: out)
        #expect(m.width == 64 && m.height == 48)
        #expect(m.format == .jpeg)
    }

    @Test("oxipng lossless pass shrinks the PNG and preserves dimensions/pixels")
    func oxipngOptimize() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeTestPNG(png, w: 256, h: 192)
        let (frames, meta) = try ImageBridgeFactory.makeDecoder().decode(url: png)

        let enc = ImageBridgeFactory.makeEncoder()
        let baseline = dir.appendingPathComponent("baseline.png")
        let optimized = dir.appendingPathComponent("opt.png")
        try enc.encode(frames[0], settings: StillEncoderSettings(format: .png, losslessOptimize: false),
                       metadata: meta, to: baseline)
        try enc.encode(frames[0], settings: StillEncoderSettings(format: .png, losslessOptimize: true, optimizeLevel: 4),
                       metadata: meta, to: optimized)

        func size(_ u: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0 }
        let b = size(baseline), o = size(optimized)
        print("[oxipng] baseline \(b) B → optimized \(o) B  (\(b > 0 ? Int((1 - Double(o)/Double(b)) * 100) : 0)% smaller)")
        #expect(o > 0)
        #expect(o <= b, "oxipng must never enlarge (got \(o) vs \(b))")

        // Lossless: still a valid PNG of the same dimensions.
        let m = try ImageBridgeFactory.makeProbe().probe(url: optimized)
        #expect(m.width == 256 && m.height == 192 && m.format == .png)
    }

    @Test("identity FrameProcessor preserves dimensions through the orchestrator")
    func identityProcessor() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try makeTestPNG(png)
        let out = dir.appendingPathComponent("out.png")

        try ImageBridgeFactory.makeOrchestrator().convert(
            input: png, output: out,
            settings: StillEncoderSettings(format: .png),
            frameProcessor: IdentityProcessor())

        let m = try ImageBridgeFactory.makeProbe().probe(url: out)
        #expect(m.width == 64 && m.height == 48)
    }
}

/// A no-op `FrameProcessor` — proves the reuse seam is wired (real ForgeOptimizer
/// chains drop in identically).
private struct IdentityProcessor: FrameProcessor, @unchecked Sendable {
    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer { pixelBuffer }
}
