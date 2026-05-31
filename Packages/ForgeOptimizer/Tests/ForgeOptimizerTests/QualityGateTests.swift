import Testing
import CoreVideo
import FormatBridge
@testable import ForgeOptimizer

@Suite("IQA-gated restoration (Step 3, #51)")
struct QualityGateTests {

    // MARK: - Fixtures

    /// A BGRA buffer whose GREEN channel (the scorer's luma proxy) is filled by
    /// `g(x, y)`.
    private func bgra(_ w: Int, _ h: Int, _ g: (Int, Int) -> UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let o = y * bpr + x * 4
                p[o + 0] = 128; p[o + 1] = g(x, y); p[o + 2] = 128; p[o + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    // MARK: - Heuristic scorer

    @Test("blockiness scorer: clean ≈ high, blocky ≈ low")
    func blockinessSeparatesCleanFromBlocky() {
        let scorer = BlockinessQualityScorer()
        // Clean: smooth horizontal ramp — uniform gradient, no grid alignment.
        let clean = bgra(256, 256) { x, _ in UInt8(x) }
        // Blocky: 8×8 block checkerboard — flat inside blocks, hard steps on the grid.
        let blocky = bgra(256, 256) { x, y in ((x / 8 + y / 8) % 2 == 0) ? 60 : 190 }

        let qClean = scorer.quality(clean)
        let qBlocky = scorer.quality(blocky)
        #expect(qClean > 0.8)
        #expect(qBlocky < 0.3)
        #expect(qClean > qBlocky)
    }

    @Test("flat frame is not mistaken for blocky")
    func flatIsClean() {
        #expect(BlockinessQualityScorer().quality(bgra(128, 128) { _, _ in 120 }) > 0.9)
    }

    // MARK: - Gate routing

    private struct FixedScorer: NoReferenceQualityScoring {
        let value: Float
        func quality(_ pixelBuffer: CVPixelBuffer) -> Float { value }
    }

    /// Records whether `process` was invoked.
    private final class RecordingProcessor: FrameProcessor, @unchecked Sendable {
        var ran = false
        func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer { ran = true; return pixelBuffer }
    }

    @Test("degraded input (quality < threshold) → restoration runs")
    func gateRunsOnDegraded() {
        let inner = RecordingProcessor()
        let gate = GatedRestorationProcessor(restoration: inner, scorer: FixedScorer(value: 0.3), threshold: 0.6)
        _ = gate.process(bgra(16, 16) { _, _ in 100 })
        #expect(inner.ran)
    }

    @Test("clean input (quality ≥ threshold) → restoration skipped, passthrough")
    func gateSkipsOnClean() {
        let inner = RecordingProcessor()
        let gate = GatedRestorationProcessor(restoration: inner, scorer: FixedScorer(value: 0.9), threshold: 0.6)
        let src = bgra(16, 16) { _, _ in 100 }
        let out = gate.process(src)
        #expect(!inner.ran)
        #expect(CVPixelBufferGetWidth(out) == 16)   // same buffer passed through
    }
}
