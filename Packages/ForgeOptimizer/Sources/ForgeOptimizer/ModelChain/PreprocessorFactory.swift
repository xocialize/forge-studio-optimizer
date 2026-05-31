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
    public static func makeChain(for level: OptimizationLevel) throws -> (any FrameProcessor)? {
        switch level {
        case .off:
            return nil

        case .light, .balanced, .aggressive, .maximum:
            let nafnet = try NAFNetProcessor()
            return ModelChain([nafnet])
        }
    }

    /// Like `makeChain`, but **IQA-gated** (Step 3, #51): NAFNet runs only on
    /// frames a no-reference scorer judges degraded; clean frames pass through,
    /// skipping the (tiled-at-4K) inference. Opt-in for now — the default ship
    /// path stays unconditional until the SigLIP2 NR-IQA head (#23) replaces the
    /// interim blockiness heuristic and the gate is validated on real content.
    ///
    /// - Parameters:
    ///   - scorer: no-reference quality signal (default: `BlockinessQualityScorer`,
    ///     license-clean; swap in `SigLIP2`-backed scoring when trained).
    ///   - threshold: run restoration when quality `< threshold` (default 0.6).
    public static func makeGatedChain(
        for level: OptimizationLevel,
        scorer: any NoReferenceQualityScoring = BlockinessQualityScorer(),
        threshold: Float = 0.6
    ) throws -> (any FrameProcessor)? {
        switch level {
        case .off:
            return nil
        case .light, .balanced, .aggressive, .maximum:
            let nafnet = try NAFNetProcessor()
            let gated = GatedRestorationProcessor(restoration: nafnet, scorer: scorer, threshold: threshold)
            return ModelChain([gated])
        }
    }
}
