import FormatBridge   // OptimizationLevel
import ForgeOptimizer
import ImageBridge

/// Wires ForgeOptimizer's SigLIP2 stack into ImageBridge's `StillOptimizer` for the
/// signage default (PRD §6 / Phase 4): one shared NR-IQA head drives the restoration gate
/// (does-restoration-pay, ADR-0016) and — optionally — the lossy encode floor.
///
/// ⚠️ FINDING (Phase-4 validation, real signage frame): SigLIP2 NR-IQA is nearly FLAT
/// across the lossy quality knob — on `clean_signage.png` it reads 0.910→0.901 as HEIC q
/// goes 1.0→0.31 (520 KB→44 KB). It's an *absolute-aesthetic / restoration-pays* signal,
/// not a *compression-fidelity* gradient, so as a lossy floor it bottoms out at minimum
/// quality (maximal compression). That's fine — even desirable — for flat graphic/text
/// signage (HEIC compresses it cleanly), but it can't protect fine detail. For
/// fidelity-critical content inject a FULL-REFERENCE metric (SSIMULACRA2, ADR-0021) as the
/// floor instead; SigLIP2's validated job here is the restoration gate. The plumbing
/// (`StillOptimizer`) is metric-agnostic, so swapping the floor is a one-liner.
public enum SignageStillOptimizer {

    /// NR-IQA lossy floor for signage (head units, [0,1]). Because the metric is flat (see
    /// the type note), this behaves as "compress maximally while NR-IQA still passes" —
    /// appropriate for flat graphic signage, NOT a fine fidelity guard. Clean signage ≈0.91.
    public static let recommendedFloor: Double = 0.85

    /// Build the optimizer. The head is loaded once (throws if the SigLIP2 backbone isn't
    /// cached — run `SigLIP2BackboneLoader.ensureWeights()` at startup).
    /// - Parameters:
    ///   - level: restoration level (`.off` → encode-only; `.balanced` default).
    ///   - gateThreshold: restoration-pays gate point (ADR-0016, ~0.78).
    ///   - maxPatches: NR-IQA patch budget.
    ///   - maxWholePixels/tileSize/overlap: print-res tiling geometry (Phase 3d).
    public static func make(
        level: OptimizationLevel = .balanced,
        gateThreshold: Float = 0.78,
        maxPatches: Int = 8,
        maxWholePixels: Int = 3840 * 2160,
        tileSize: Int = 512,
        overlap: Int = 32
    ) throws -> StillOptimizer {
        let head = try SigLIP2NRIQAScorer(maxPatches: maxPatches)
        let restoration = try StillRestorationFactory.makeTiledRestoration(
            level: level, scorer: head, threshold: gateThreshold,
            maxWholePixels: maxWholePixels, tileSize: tileSize, overlap: overlap)
        return ImageBridgeFactory.makeOptimizer(scorer: SigLIP2StillScorer(head), frameProcessor: restoration)
    }

    /// Recommended settings for a lossy signage target (HEIC/JPEG) at the calibrated floor.
    public static func settings(format: StillOutputFormat, restore: Bool = true) -> StillOptimizationSettings {
        StillOptimizationSettings(
            format: format, restore: restore,
            search: StillQualityTargetSearch(targetScore: recommendedFloor,
                                             qualityRange: 0.3 ... 1.0, slack: 0.0, maxProbes: 8))
    }
}
