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
}
