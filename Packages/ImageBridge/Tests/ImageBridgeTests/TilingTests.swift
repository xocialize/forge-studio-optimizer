import Testing
import Foundation
import CoreVideo
import FormatBridge
@testable import ImageBridge

@Suite("ImageBridge print-res tiling (Phase 3)")
struct TilingTests {

    // MARK: - buffer helpers

    private func gradientBGRA(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< h { for x in 0 ..< w {
            let o = y * bpr + x * 4
            p[o] = UInt8(x % 256); p[o + 1] = UInt8(y % 256); p[o + 2] = UInt8((x + y) % 256); p[o + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    /// Max abs B/G/R difference between two buffers of equal size.
    private func maxDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let aBPR = CVPixelBufferGetBytesPerRow(a), bBPR = CVPixelBufferGetBytesPerRow(b)
        let ap = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let bp = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        var m = 0
        for y in 0 ..< h { for x in 0 ..< w { for c in 0 ..< 3 {
            m = max(m, abs(Int(ap[y * aBPR + x * 4 + c]) - Int(bp[y * bBPR + x * 4 + c])))
        } } }
        return m
    }

    @Test("identity tiling reassembles a large frame losslessly")
    func identityLossless() throws {
        let src = gradientBGRA(700, 500)
        let tiled = TiledFrameProcessor(inner: IdentityProc(), maxWholePixels: 10_000, tileSize: 128, overlap: 16)
        let out = tiled.process(src)
        #expect(CVPixelBufferGetWidth(out) == 700 && CVPixelBufferGetHeight(out) == 500)
        let d = maxDiff(src, out)
        print("[tile] identity reassembly maxDiff=\(d)")
        #expect(d == 0, "tiling + identity must reassemble exactly, got \(d)")
    }

    @Test("tiling a pixel-local op equals the whole-frame result")
    func tilingMatchesWholeFrame() throws {
        let src = gradientBGRA(640, 384)
        let whole = InvertProc().process(src)                       // ground truth, single pass
        let tiled = TiledFrameProcessor(inner: InvertProc(), maxWholePixels: 10_000, tileSize: 128, overlap: 16)
            .process(src)
        let d = maxDiff(whole, tiled)
        print("[tile] tiled-vs-whole maxDiff=\(d)")
        #expect(d <= 1, "tiled invert must match whole-frame invert within rounding, got \(d)")
    }

    @Test("at/below the budget it's a whole-frame passthrough; above it tiles")
    func routing() throws {
        // Small (≤ budget) → one whole-frame call at full size.
        let spySmall = SpyProc()
        _ = TiledFrameProcessor(inner: spySmall, maxWholePixels: 64 * 64, tileSize: 128, overlap: 16)
            .process(gradientBGRA(64, 64))
        #expect(spySmall.sizes == [Size(w: 64, h: 64)], "whole-frame path, got \(spySmall.sizes)")

        // Large (> budget) → many tile-sized calls, none exceeding the tile size.
        let spyBig = SpyProc()
        _ = TiledFrameProcessor(inner: spyBig, maxWholePixels: 64 * 64, tileSize: 128, overlap: 16)
            .process(gradientBGRA(400, 300))
        #expect(spyBig.sizes.count > 1, "should have tiled, got \(spyBig.sizes.count) calls")
        #expect(spyBig.sizes.allSatisfy { $0.w <= 128 && $0.h <= 128 }, "tiles bounded, got \(spyBig.sizes)")
        print("[tile] 400×300 @128/16 → \(spyBig.sizes.count) tiles")
    }
}

// MARK: - synthetic processors

private struct IdentityProc: FrameProcessor, @unchecked Sendable {
    func process(_ pb: CVPixelBuffer) -> CVPixelBuffer { pb }
}

/// Pixel-local invert (no receptive field) → tiling must be exactly equivalent.
private struct InvertProc: FrameProcessor, @unchecked Sendable {
    func process(_ src: CVPixelBuffer) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        let out = pb!
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []); CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        let sBPR = CVPixelBufferGetBytesPerRow(src), oBPR = CVPixelBufferGetBytesPerRow(out)
        let sp = CVPixelBufferGetBaseAddress(src)!.assumingMemoryBound(to: UInt8.self)
        let op = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< h { for x in 0 ..< w {
            let s = y * sBPR + x * 4, o = y * oBPR + x * 4
            op[o] = 255 - sp[s]; op[o + 1] = 255 - sp[s + 1]; op[o + 2] = 255 - sp[s + 2]; op[o + 3] = 255
        } }
        return out
    }
}

private struct Size: Equatable { let w: Int; let h: Int }

/// Records the size of every buffer it's handed (calls are serial within the tiler).
private final class SpyProc: FrameProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private var _sizes: [Size] = []
    var sizes: [Size] { lock.lock(); defer { lock.unlock() }; return _sizes }
    func process(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        lock.lock(); _sizes.append(Size(w: CVPixelBufferGetWidth(pb), h: CVPixelBufferGetHeight(pb))); lock.unlock()
        return pb
    }
}
