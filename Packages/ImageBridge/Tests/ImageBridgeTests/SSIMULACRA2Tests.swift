import Testing
import Foundation
import CoreVideo
@testable import ImageBridge

@Suite("ImageBridge SSIMULACRA2 full-reference scorer (#71)")
struct SSIMULACRA2Tests {

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ibs2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A detailed BGRA buffer (gradient + high-frequency noise) so JPEG quality is
    /// genuinely discriminative — flat fills compress for free and don't exercise a floor.
    private func detailedBuffer(_ w: Int = 320, _ h: Int = 256) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
        for y in 0 ..< h { for x in 0 ..< w {
            let o = y * bpr + x * 4
            let n = ((x * 7 + y * 13) % 53) - 26          // deterministic high-freq noise ±26
            let m = ((x &* 31 &+ y &* 17) % 47) - 23
            p[o]     = clamp(x * 255 / w + n)             // B
            p[o + 1] = clamp(y * 255 / h + m)             // G
            p[o + 2] = clamp((x + y) * 255 / (w + h) + n) // R
            p[o + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    private func writePNG(_ buf: CVPixelBuffer, _ url: URL) throws {
        try ImageBridgeFactory.makeEncoder().encode(
            buf, settings: StillEncoderSettings(format: .png, losslessOptimize: false), metadata: nil, to: url)
    }

    @Test("monotonic with quality (where SigLIP2 NR-IQA was flat); identical ≈ 100")
    func monotonic() throws {
        guard BinarySSIMULACRA2Scorer.isAvailable() else {
            print("[s2] ssimulacra2 binary absent → skip (brew install jpeg-xl)"); return
        }
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ref = detailedBuffer()
        let scorer = try BinarySSIMULACRA2Scorer()

        #expect(scorer.score(reference: ref, distorted: ref) > 99, "identical buffers ≈ 100")

        var prev = 101.0
        for q in [0.95, 0.7, 0.45, 0.2] {
            let jpg = dir.appendingPathComponent("q\(Int(q * 100)).jpg")
            try ImageBridgeFactory.makeEncoder().encode(
                ref, settings: StillEncoderSettings(format: .jpeg, quality: q), metadata: nil, to: jpg)
            let cand = try ImageBridgeFactory.makeDecoder().decode(url: jpg).frames[0]
            let s = scorer.score(reference: ref, distorted: cand)
            print("[s2] q=\(q) → \(String(format: "%.2f", s))")
            #expect(s > 0 && s < 100)
            #expect(s < prev, "score must drop as quality drops (q=\(q): \(s) !< \(prev))")
            prev = s
        }
    }

    @Test("SSIMULACRA2 floor makes the optimizer pick a sensible quality, not the minimum")
    func optimizerFloorIsMeaningful() throws {
        guard BinarySSIMULACRA2Scorer.isAvailable() else {
            print("[s2] ssimulacra2 binary absent → skip"); return
        }
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"); try writePNG(detailedBuffer(), png)
        let out = dir.appendingPathComponent("out.jpg")

        let floor = 80.0
        let opt = ImageBridgeFactory.makeOptimizer(scorer: try BinarySSIMULACRA2Scorer(), frameProcessor: nil)
        let r = try opt.optimize(input: png, output: out, settings: StillOptimizationSettings(
            format: .jpeg, restore: false,
            search: StillQualityTargetSearch(targetScore: floor, qualityRange: 0.3 ... 1.0, slack: 1.0, maxProbes: 8)))
        let t = try #require(r.target)
        print("[s2] optimizer floor=\(floor) → q=\(String(format: "%.3f", t.quality)) score=\(String(format: "%.2f", t.achievedScore)) bytes=\(r.outputBytes)")
        #expect(t.metTarget)
        #expect(t.achievedScore >= floor - 1.0)
        // The point of #71: a real fidelity gradient drives the search ABOVE the floor of
        // the range — not bottomed out at min like the flat NR-IQA was.
        #expect(t.quality > 0.35, "search must respond to the floor, got q=\(t.quality)")
    }
}
