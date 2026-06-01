import CoreVideo
import FormatBridge

/// IQA-gated restoration (Step 3, #51): runs the wrapped restoration processor
/// (NAFNet) **only when the input looks degraded**, otherwise passes the frame
/// through untouched.
///
/// Motivated by a measured finding (CLAUDE.md / real-signage eval): NAFNet is
/// ~neutral on already-clean content (≈ +0.24 VMAF for ~2% size) but a clear win
/// on degraded input. Gating skips the model on clean frames — saving the
/// (expensive, tiled-at-4K) inference and avoiding the slight size bump — with no
/// quality cost where it matters.
///
/// A `FrameProcessor` decorator, so it composes in a `ModelChain` exactly where
/// `NAFNetProcessor` sits today; the quality signal is injected
/// (`NoReferenceQualityScoring`) so the interim heuristic and the eventual
/// SigLIP2 NR-IQA head are interchangeable.
public final class GatedRestorationProcessor: FrameProcessor, @unchecked Sendable {

    private let restoration: any FrameProcessor
    private let scorer: any NoReferenceQualityScoring
    /// Run restoration when `quality < threshold`. Default **0.78**, calibrated
    /// for the SigLIP2 NR-IQA head in the real-frame eval (ADR-0016): the clean
    /// floor sits ≈0.84 and the degradation-where-NAFNet-helps cluster ≈0.70–0.74,
    /// so 0.78 separates them. (The interim blockiness baseline used 0.6.)
    private let threshold: Float

    public init(restoration: any FrameProcessor,
                scorer: any NoReferenceQualityScoring,
                threshold: Float = 0.78) {
        self.restoration = restoration
        self.scorer = scorer
        self.threshold = threshold
    }

    public func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let q = scorer.quality(pixelBuffer)
        return q < threshold ? restoration.process(pixelBuffer) : pixelBuffer
    }
}
