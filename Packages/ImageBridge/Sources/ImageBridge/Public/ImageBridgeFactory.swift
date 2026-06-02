import Foundation

/// Public entry point — mirrors `FormatBridgeFactory` (PRD §8). Phase 1 wires the
/// native ImageIO probe/decode/encode + the passthrough orchestrator. The
/// quality-target encoder (still analog of the VMAF-target search) lands in
/// Phase 2 with the `StillQualityScoring` seam.
public enum ImageBridgeFactory {

    public static func makeProbe() -> any StillMediaProbing {
        ImageIOProbeImpl()
    }

    public static func makeDecoder() -> any StillDecoding {
        ImageIODecoderImpl()
    }

    public static func makeEncoder() -> any StillEncoding {
        ImageIOEncoderImpl()
    }

    /// End-to-end orchestrator. Pass a `ForgeOptimizer.ModelChain` as the
    /// `frameProcessor` at the call site to run the AI chain unchanged; `nil`
    /// (the default) is a passthrough conversion.
    public static func makeOrchestrator() -> any StillConversionOrchestrating {
        StillConversionOrchestratorImpl(decoder: ImageIODecoderImpl(), encoder: ImageIOEncoderImpl())
    }

    /// Animated GIF/APNG → MP4 (ADR-0022) via FormatBridge's VideoToolbox encoder.
    /// The only ImageBridge path that emits video; static stills use `makeOrchestrator`.
    public static func makeAnimatedToVideoConverter() -> AnimatedToVideoConverter {
        AnimatedToVideoConverter(decoder: ImageIODecoderImpl())
    }

    /// Quality-targeted lossy encoder (PRD §6) — smallest JPEG/HEIC clearing the
    /// injected perceptual floor. `scorer` is supplied by the runner (SigLIP2
    /// NR-IQA for signage, or SSIMULACRA2 full-ref), never linked into the bridge.
    public static func makeQualityTargetEncoder(
        scorer: any StillQualityScoring,
        search: StillQualityTargetSearch
    ) -> StillQualityTargetEncoder {
        StillQualityTargetEncoder(encoder: ImageIOEncoderImpl(), decoder: ImageIODecoderImpl(),
                                  scorer: scorer, search: search)
    }
}
