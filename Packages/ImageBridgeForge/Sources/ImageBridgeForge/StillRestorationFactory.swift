import CoreVideo
import ForgeOptimizer
import FormatBridge
import ImageBridge

/// Builds the still-image restoration `FrameProcessor`: ForgeOptimizer's IQA-gated
/// NAFNet chain (ADR-0016), wrapped in ImageBridge's `TiledFrameProcessor` so a
/// print-resolution still (e.g. a 6000×4000 poster) is restored tile-by-tile instead
/// of OOMing the MLX model at full res (PRD §4 "tiling mandatory"). Pass the result as
/// `frameProcessor` to `ImageBridgeFactory.makeOrchestrator().convert(...)`.
///
/// This is the only place tiling + the learned chain meet: ImageBridge stays MLX-free
/// (the tiler is pure CVPixelBuffer), ForgeOptimizer stays still-agnostic, and this glue
/// composes them. The IQA gate still runs per tile, which is conservative-correct — a
/// tile of clean sky skips restoration while a tile of compressed text gets it.
public enum StillRestorationFactory {

    /// - Parameters:
    ///   - level: optimization level (`.off` → returns nil; no restoration).
    ///   - scorer: IQA gate scorer (default: the SigLIP2 NR-IQA head if its backbone is
    ///     cached, else unconditional NAFNet — same fallback as the video chain).
    ///   - threshold: restoration-pays gate point (ADR-0016, ~0.78).
    ///   - maxWholePixels: whole-frame budget; above it the chain tiles. Default 4K.
    ///   - tileSize / overlap: tile geometry (512 / 32 feather).
    public static func makeTiledRestoration(
        level: OptimizationLevel = .balanced,
        scorer: (any NoReferenceQualityScoring)? = nil,
        threshold: Float = 0.78,
        maxWholePixels: Int = 3840 * 2160,
        tileSize: Int = 512,
        overlap: Int = 32
    ) throws -> (any FrameProcessor)? {
        guard let chain = try PreprocessorFactory.makeGatedChain(
            for: level, scorer: scorer, threshold: threshold) else {
            return nil   // .off → passthrough (orchestrator runs no processor)
        }
        return TiledFrameProcessor(inner: chain, maxWholePixels: maxWholePixels,
                                   tileSize: tileSize, overlap: overlap)
    }
}
