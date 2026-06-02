import CoreVideo
import ForgeOptimizer
import ImageBridge

/// Injects ForgeOptimizer's SigLIP2 NR-IQA head (ADR-0016) into ImageBridge's
/// `StillQualityScoring` seam — the chosen default still metric (PRD §6 / ADR-0021).
///
/// No-reference: scores the candidate alone (ignores `reference`), which is the
/// honest choice for signage where the "original" is often itself degraded. The
/// score is the head's quality in [0, 1]; set the search floor in the same units
/// (e.g. ~0.85). The same head powers the video IQA gate (#51) and ImageBridge —
/// one model, both pipelines.
public struct SigLIP2StillScorer: StillQualityScoring, @unchecked Sendable {

    private let scorer: SigLIP2NRIQAScorer

    /// Resolve the head + cached 8-bit backbone from the standard locations
    /// (`SigLIP2BackboneLoader` cache + ForgeOptimizer Resources). Throws if the
    /// backbone isn't cached yet (run `SigLIP2BackboneLoader.ensureWeights()`).
    public init(maxPatches: Int = 8) throws {
        self.scorer = try SigLIP2NRIQAScorer(maxPatches: maxPatches)
    }

    /// Inject a pre-built scorer (e.g. one shared with the video gate).
    public init(_ scorer: SigLIP2NRIQAScorer) {
        self.scorer = scorer
    }

    public func score(reference: CVPixelBuffer, distorted: CVPixelBuffer) -> Double {
        Double(scorer.quality(distorted))   // no-reference → `reference` unused
    }
}
