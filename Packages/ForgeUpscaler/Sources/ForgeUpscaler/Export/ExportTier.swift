// ExportTier.swift
//
// Role: Backend-agnostic abstraction for the ForgeUpscaler export tier.
//       Concrete tiers (Real-ESRGAN CoreML today, OSEDiff MLX in the future)
//       conform to `ExportTier` so `ExportUpscaler` can swap engines without
//       changing call sites.
//
// Plan reference: Docs/Forge-CodingPlan-v1.0.md §D
// ADR:           Docs/ADRs/0007-real-esrgan-export-tier.md
//
// Conventions:
// - Public, Sendable surface.
// - Errors as a Sendable enum; no NSError shaping.
// - `inputTileSize` reports the tile dimension the tier feeds its model.
//   The plan §D.2 specifies 256 with 32 px overlap; the currently-vendored
//   CoreML mlpackage uses a fixed 128 input, so Real-ESRGAN CoreML reports
//   128 / 16. The protocol is shape-honest, not plan-prescriptive.

import CoreVideo
import Foundation

/// A pluggable backend for ForgeUpscaler's export (offline, max-quality) tier.
///
/// Tiers wrap a model + tile-driver pair behind a uniform call. The
/// `ExportUpscaler` selects a concrete tier at init time and delegates
/// every `upscale(_:)` to it; the `ExportPipeline` orchestrator is
/// unaware of which tier is in use.
public protocol ExportTier: Sendable {

    /// Stable identifier for logs / benchmarks. Examples:
    /// `"real-esrgan-coreml"`, `"real-esrgan-mlx"`, `"osediff-mlx"`.
    var name: String { get }

    /// Spatial upscale factor (2 or 4).
    var scaleFactor: Int { get }

    /// Edge length of one model-input tile, in input-resolution pixels.
    /// `inputResolution.width` and `.height` mirror this for callers that
    /// prefer the tuple form.
    var inputTileSize: Int { get }

    /// Convenience: `(inputTileSize, inputTileSize)`. Reported as a tuple
    /// to align with the protocol surface the task brief specified, and to
    /// leave room for future tiers whose models are non-square.
    var inputResolution: (width: Int, height: Int) { get }

    /// Convenience: `(inputTileSize * scaleFactor, inputTileSize * scaleFactor)`.
    var outputResolution: (width: Int, height: Int) { get }

    /// Tile-to-tile overlap in input-resolution pixels. Phase D.2 calls for
    /// 32 (against a 256 tile); the current CoreML tier uses 16 (against 128).
    var tileOverlap: Int { get }

    /// Run the tier on a full-frame `CVPixelBuffer`. Implementations are
    /// expected to internally tile the input through the model and return
    /// a buffer at `scaleFactor`× the input dimensions.
    func upscale(_ buffer: CVPixelBuffer) async throws -> CVPixelBuffer
}

/// Errors thrown by `ExportTier` implementations.
public enum ExportTierError: Error, Sendable, CustomStringConvertible {

    /// The backend's weights / model could not be located or compiled.
    /// Carries a human-readable detail (model name, path, underlying error).
    case modelLoadFailed(String)

    /// The requested upscale factor is not supported by this tier.
    case unsupportedScale(Int)

    /// The tier is a forward-looking stub. `OSEDiff_MLX` returns this for
    /// every `upscale(_:)` until DiffusionKit's SD 2.1 path matures.
    case notYetImplemented(String)

    /// Inference itself failed (CoreML / MLX returned no output, shape
    /// mismatch, etc.). Carries a human-readable detail.
    case inferenceFailed(String)

    public var description: String {
        switch self {
        case .modelLoadFailed(let detail):
            return "ExportTier model load failed: \(detail)"
        case .unsupportedScale(let scale):
            return "ExportTier does not support scale=\(scale)"
        case .notYetImplemented(let detail):
            return "ExportTier not yet implemented: \(detail)"
        case .inferenceFailed(let detail):
            return "ExportTier inference failed: \(detail)"
        }
    }
}
