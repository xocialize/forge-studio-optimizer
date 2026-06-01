import FormatBridge
import Foundation

/// Builds a FrameProcessor chain based on OptimizationLevel.
///
/// Phase B.5 (Task #14): NAFNet — the trained MLX restoration model — replaces
/// the v0.3 256²-resize `Denoiser` + `ArtifactRemover` stub chain. One
/// fully-convolutional model handles both Gaussian-noise denoising and
/// HEVC/AV1/MPEG-2 compression-artifact removal at the frame's native
/// resolution. Restoration is uniform across every non-`.off` level (NAFNet has
/// no intensity knob); the levels differ on the *encode* side (quality preset),
/// not the restoration model.
///
///   .off                                   → nil (no preprocessing)
///   .light / .balanced / .aggressive / .maximum → [NAFNetProcessor]
///
/// The v0.3 stubs remain under `Restoration/Legacy/` for reference / the
/// CoreML ModelRegistry path; they are simply no longer wired here.
public enum PreprocessorFactory {

    /// Create a FrameProcessor chain for the given optimization level.
    /// Returns nil for `.off`. Throws if the NAFNet weights can't be loaded.
    ///
    /// **Default-on IQA gate (ADR-0016):** restoration is gated by the learned
    /// SigLIP2 NR-IQA head — NAFNet runs only on frames it judges degraded enough
    /// to benefit (the "restoration-pays" signal, validated `SigLIP2GateTests`).
    /// If the lazy-downloaded backbone (~400 MB, ADR-0005) isn't cached yet, this
    /// falls back to **unconditional NAFNet** (the pre-gate ship behavior).
    public static func makeChain(for level: OptimizationLevel) throws -> (any FrameProcessor)? {
        try makeGatedChain(for: level)
    }

    /// IQA-gated chain (Step 3, #51 / ADR-0016): NAFNet runs only on frames the
    /// scorer judges degraded; clean frames pass through, skipping the
    /// (tiled-at-4K) inference and avoiding the slight size bump.
    ///
    /// - Parameters:
    ///   - scorer: explicit no-reference quality signal. When `nil` (the default),
    ///     uses the learned `SigLIP2NRIQAScorer`; if its backbone isn't cached,
    ///     falls back to **unconditional NAFNet** (NOT the unfit blockiness
    ///     heuristic — see ADR-0016 / Conventions).
    ///   - threshold: run restoration when quality `< threshold` (default **0.78**,
    ///     calibrated in the real-frame eval: clean floor ≈0.84, run-cluster ≈0.70–0.74).
    public static func makeGatedChain(
        for level: OptimizationLevel,
        scorer explicitScorer: (any NoReferenceQualityScoring)? = nil,
        threshold: Float = 0.78
    ) throws -> (any FrameProcessor)? {
        switch level {
        case .off:
            return nil
        case .light, .balanced, .aggressive, .maximum:
            let nafnet = try NAFNetProcessor()
            // Default gate = learned SigLIP2 head; fall back to unconditional
            // NAFNet if the backbone isn't cached (graceful — never the unfit
            // blockiness baseline, which mis-gated real signage).
            guard let scorer = explicitScorer ?? (try? SigLIP2NRIQAScorer()) else {
                return ModelChain([nafnet])
            }
            let gated = GatedRestorationProcessor(restoration: nafnet, scorer: scorer, threshold: threshold)
            return ModelChain([gated])
        }
    }
}
