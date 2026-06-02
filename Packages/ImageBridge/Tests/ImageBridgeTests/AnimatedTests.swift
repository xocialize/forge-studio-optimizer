import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FormatBridge
@testable import ImageBridge

@Suite("ImageBridge animated GIF → MP4 (Phase 3, ADR-0022)")
struct AnimatedTests {

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("iba-anim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func solid(_ w: Int, _ h: Int, _ c: CGColor) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(c); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// 3-frame GIF, odd 129×97 (to exercise even-crop), 0.2 s/frame.
    private func makeAnimatedGIF(_ url: URL) {
        let frames = [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 1, alpha: 1)]
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for c in frames {
            CGImageDestinationAddImage(dest, solid(129, 97, c),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        _ = CGImageDestinationFinalize(dest)
    }

    @Test("decode reports per-frame delays for an animated GIF")
    func extractsDelays() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let gif = dir.appendingPathComponent("a.gif"); makeAnimatedGIF(gif)
        let m = try ImageBridgeFactory.makeProbe().probe(url: gif)
        #expect(m.format == .gif)
        #expect(m.frameCount == 3)
        let delays = try #require(m.frameDelays)
        #expect(delays.count == 3)
        #expect(delays.allSatisfy { abs($0 - 0.2) < 0.01 }, "got \(delays)")
    }

    @Test("animated GIF transcodes to a playable MP4 with the source timing + even dims")
    func transcodesToMP4() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let gif = dir.appendingPathComponent("a.gif"); makeAnimatedGIF(gif)
        let mp4 = dir.appendingPathComponent("a.mp4")

        let n = try await ImageBridgeFactory.makeAnimatedToVideoConverter().convert(input: gif, output: mp4)
        #expect(n == 3, "all frames written")
        #expect(FileManager.default.fileExists(atPath: mp4.path))

        // Validate the OUTPUT with the video probe, not just the return value.
        let info = try await FormatBridgeFactory.makeProbe().probe(url: mp4)
        let v = try #require(info.videoStreams.first)
        print("[anim] mp4 \(v.width)x\(v.height) dur=\(String(format: "%.2f", info.duration.seconds))s")
        #expect(v.width == 128 && v.height == 96, "129×97 cropped to even 128×96, got \(v.width)x\(v.height)")
        #expect(info.duration.seconds > 0.4 && info.duration.seconds < 0.9, "≈3×0.2s = 0.6s")
    }

    @Test("a single still is rejected (use the still path)")
    func rejectsSingleStill() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("one.png")
        let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, solid(16, 16, CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)), nil)
        _ = CGImageDestinationFinalize(dest)
        await #expect(throws: ImageBridgeError.self) {
            _ = try await ImageBridgeFactory.makeAnimatedToVideoConverter().convert(
                input: png, output: dir.appendingPathComponent("x.mp4"))
        }
    }
}
