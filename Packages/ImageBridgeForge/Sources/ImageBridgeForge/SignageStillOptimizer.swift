import FormatBridge   // OptimizationLevel
import ForgeOptimizer
import ImageBridge

/// Wires the signage default `StillOptimizer` (PRD §6 / Phase 4) with the RIGHT metric in
/// each role — the Phase-4 + #71 conclusion:
///
/// - **Restoration gate = SigLIP2 NR-IQA** (does-restoration-pay, ADR-0016). Its validated
///   job: an absolute-aesthetic signal that decides whether NAFNet helps.
/// - **Lossy encode floor = SSIMULACRA2** (full-reference, #71). SigLIP2 is nearly FLAT
///   across the compression knob (0.910→0.901 from HEIC q1.0→0.31 on a real frame), so it
///   can't protect fine detail; SSIMULACRA2 is a true fidelity-vs-reference gradient
///   (monotonic), used at encode time exactly like libvmaf on the video side.
///
/// So the head loads once (gate), and the lossy floor shells out to the `ssimulacra2`
/// reference binary (`brew install jpeg-xl`). For PNG/lossless targets the floor is unused.
public enum SignageStillOptimizer {

    /// Recommended SSIMULACRA2 lossy floor for signage (−∞…100; 90 ≈ visually lossless at 1:1).
    public static let recommendedFloor: Double = BinarySSIMULACRA2Scorer.recommendedFloor

    /// Build the optimizer. Loads the SigLIP2 head once for the restoration gate (throws if
    /// the backbone isn't cached — run `SigLIP2BackboneLoader.ensureWeights()` at startup),
    /// and resolves the SSIMULACRA2 lossy floor (throws if the binary is missing, unless a
    /// `lossyFloor` is injected — e.g. a future pure-Swift port).
    /// - Parameters:
    ///   - level: restoration level (`.off` → encode-only; `.balanced` default).
    ///   - gateThreshold: restoration-pays gate point (ADR-0016, ~0.78).
    ///   - lossyFloor: override the encode-floor metric (default: SSIMULACRA2 binary).
    ///   - maxPatches: NR-IQA patch budget.
    ///   - maxWholePixels/tileSize/overlap: print-res tiling geometry (Phase 3d).
    public static func make(
        level: OptimizationLevel = .balanced,
        gateThreshold: Float = 0.78,
        lossyFloor: (any StillQualityScoring)? = nil,
        maxPatches: Int = 8,
        maxWholePixels: Int = 3840 * 2160,
        tileSize: Int = 512,
        overlap: Int = 32
    ) throws -> StillOptimizer {
        let head = try SigLIP2NRIQAScorer(maxPatches: maxPatches)
        let restoration = try StillRestorationFactory.makeTiledRestoration(
            level: level, scorer: head, threshold: gateThreshold,
            maxWholePixels: maxWholePixels, tileSize: tileSize, overlap: overlap)
        let floor = try lossyFloor ?? BinarySSIMULACRA2Scorer()
        return ImageBridgeFactory.makeOptimizer(scorer: floor, frameProcessor: restoration)
    }

    /// Recommended settings for a lossy signage target (HEIC/AVIF/JPEG) at the SSIMULACRA2 floor.
    public static func settings(format: StillOutputFormat, restore: Bool = true,
                                floor: Double = recommendedFloor) -> StillOptimizationSettings {
        StillOptimizationSettings(
            format: format, restore: restore,
            search: StillQualityTargetSearch(targetScore: floor,
                                             qualityRange: 0.3 ... 1.0, slack: 1.0, maxProbes: 8))
    }
}
