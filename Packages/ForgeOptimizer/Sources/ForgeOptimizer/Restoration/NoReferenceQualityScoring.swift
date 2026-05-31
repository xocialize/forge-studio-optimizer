import CoreVideo

/// No-reference perceptual quality estimate for the IQA-gated restoration path
/// (Step 3, #51).
///
/// "No-reference" because the gate runs on the *input* with no pristine original
/// to compare against — the whole point is to decide, from the degraded frame
/// alone, whether restoration is worth running. A seam (like `QualityScoring` on
/// the encode side) so the gate is independent of which scorer backs it: an
/// interim heuristic ships today; the SigLIP2 NR-IQA head (`SigLIP2_IQA`, #23)
/// drops in unchanged once trained.
public protocol NoReferenceQualityScoring: Sendable {
    /// Estimated perceptual quality in `[0, 1]` — **1 = pristine, 0 = heavily
    /// degraded**. The gate runs restoration when this falls below a threshold.
    func quality(_ pixelBuffer: CVPixelBuffer) -> Float
}
