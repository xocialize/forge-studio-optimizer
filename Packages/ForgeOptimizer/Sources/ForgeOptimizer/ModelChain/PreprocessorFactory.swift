import FormatBridge
import Foundation

/// Builds a FrameProcessor chain based on OptimizationLevel.
///
/// Maps Forge PRD v0.3 optimization levels to CoreML model chains:
///   .off       → nil (no preprocessing)
///   .light     → [Denoiser]
///   .balanced  → [Denoiser]  (SoftROIFilter is GPU-based, added later)
///   .aggressive → [Denoiser, ArtifactRemover]
///   .maximum   → [Denoiser, ArtifactRemover]  (ESPCN handled separately)
public enum PreprocessorFactory {

    /// Create a FrameProcessor chain for the given optimization level.
    /// Returns nil for `.off`.
    public static func makeChain(for level: OptimizationLevel) throws -> (any FrameProcessor)? {
        switch level {
        case .off:
            return nil

        case .light:
            let denoiser = try Denoiser()
            return ModelChain([denoiser])

        case .balanced:
            let denoiser = try Denoiser()
            // SoftROIFilter (GPU CIColorKernel) will be added here when implemented
            return ModelChain([denoiser])

        case .aggressive:
            let denoiser = try Denoiser()
            let arcnn = try ArtifactRemover()
            return ModelChain([denoiser, arcnn])

        case .maximum:
            let denoiser = try Denoiser()
            let arcnn = try ArtifactRemover()
            // ESPCN super-resolution is applied separately (changes resolution)
            return ModelChain([denoiser, arcnn])
        }
    }
}
