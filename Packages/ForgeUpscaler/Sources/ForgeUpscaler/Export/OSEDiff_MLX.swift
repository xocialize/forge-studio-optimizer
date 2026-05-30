// OSEDiff_MLX.swift
//
// Role: Forward-looking `ExportTier` stub for OSEDiff (One-Step Effective
//       Diffusion super-resolution) on MLX. The protocol surface compiles
//       today so call sites can reference it; every method throws
//       `ExportTierError.notYetImplemented` until DiffusionKit's SD 2.1
//       path matures.
//
// Plan reference: Docs/Forge-CodingPlan-v1.0.md §D.3
// Re-eval ref:    Docs/Forge-Re-Evaluation-2026-05.md §2.6 (watch-list)
//
// Revisit trigger:
//   - DiffusionKit releases a Swift-callable SD 2.1 UNet path on Apple
//     Silicon with FP16 weights ≤ 1.5 GB, OR
//   - 2026-Q3 calendar check, whichever fires first.
// Until then, leave this file as the protocol-level placeholder. Do not
// add a partial implementation — a half-baked diffusion path would burn
// reviewer cycles and obscure the export tier's currently-shipping
// Real-ESRGAN CoreML backend.

import CoreVideo
import Foundation

/// Stub `ExportTier` for OSEDiff (one-step diffusion SR). Construction
/// succeeds so wiring tests can verify the protocol surface; every
/// `upscale(_:)` call throws `ExportTierError.notYetImplemented`.
public final class OSEDiff_MLX: ExportTier, @unchecked Sendable {

    public let name: String = "osediff-mlx"
    public let scaleFactor: Int
    public let inputTileSize: Int
    public let tileOverlap: Int

    public var inputResolution: (width: Int, height: Int) {
        (inputTileSize, inputTileSize)
    }

    public var outputResolution: (width: Int, height: Int) {
        (inputTileSize * scaleFactor, inputTileSize * scaleFactor)
    }

    /// Construct a stub OSEDiff tier. No model loading happens; this
    /// merely records the shape the eventual implementation will use.
    /// - Parameters:
    ///   - scale: Target upscale factor (4 by default). OSEDiff is
    ///     diffusion-based and not naturally tied to a discrete scale,
    ///     but the protocol contract requires one.
    ///   - tileSize: Reserved for future tiled diffusion; reported but
    ///     not yet exercised.
    ///   - tileOverlap: As above.
    public init(scale: Int = 4, tileSize: Int = 256, tileOverlap: Int = 32) {
        self.scaleFactor = scale
        self.inputTileSize = tileSize
        self.tileOverlap = tileOverlap
    }

    public func upscale(_ buffer: CVPixelBuffer) async throws -> CVPixelBuffer {
        _ = buffer
        throw ExportTierError.notYetImplemented(
            "OSEDiff requires DiffusionKit SD 2.1 path; revisit 2026-Q3 per Forge-CodingPlan-v1.0.md §D.3"
        )
    }
}
