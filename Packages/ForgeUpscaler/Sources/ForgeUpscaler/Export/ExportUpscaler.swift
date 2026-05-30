// ExportUpscaler.swift
//
// Role: High-quality offline (max-quality, 3-10 s/frame) upscaler. Delegates
//       all model work to a concrete `ExportTier`; this class is a thin
//       façade that records the active tier and forwards `upscale(_:)`.
//
// Plan reference: Docs/Forge-CodingPlan-v1.0.md §D
// ADR:           Docs/ADRs/0007-real-esrgan-export-tier.md
// Tier today:    `RealESRGAN_CoreML` (BSD-3-Clause, vendored mlpackages)
// Tier future:   `OSEDiff_MLX` (stub; revisit 2026-Q3 per §D.3)
//
// Behavior notes:
// - `ContentPreset.anime` resolves to the same tier as `.general`. Anime-
//   specific Real-ESRGAN weights are future work (§F / PRD §4.4).
// - The legacy `init(modelURL:scale:tileSize:tileOverlap:)` signature is
//   preserved so `ForgeUpscaler.init(tier:modelURL:scale:...)` still
//   compiles; it constructs a `RealESRGAN_CoreML` against the supplied URL.

import CoreVideo
import Foundation

/// High-quality offline upscaler. Backend-agnostic — wraps an `ExportTier`.
///
/// Targets maximum quality at 3-10 seconds per frame for permanent file
/// conversion (DVD → 1080p, 1080p → 4K, 4K → 8K).
public final class ExportUpscaler: @unchecked Sendable {

    /// The active export tier. Public so `ExportPipeline` / benchmarks can
    /// report `tier.name`.
    public let tier: ExportTier

    /// Upscale factor reported by the active tier. Preserved for source
    /// compatibility with the previous `ExportUpscaler.scale` field.
    public var scale: Int { tier.scaleFactor }

    // MARK: - Init

    /// Initialise from an explicit `ExportTier`. Tests and advanced
    /// callers use this to inject a custom tier.
    public init(tier: ExportTier) {
        self.tier = tier
    }

    /// Initialise from a content preset using bundled models. Resolves to
    /// `RealESRGAN_CoreML` today; `OSEDiff_MLX` is wired up but stubbed.
    public convenience init(
        preset: ForgeUpscaler.ContentPreset = .general,
        scale: Int = 4
    ) throws {
        let tier = try RealESRGAN_CoreML(preset: preset, scale: scale)
        self.init(tier: tier)
    }

    /// Initialise from an explicit `.mlpackage` URL. Used by
    /// `ForgeUpscaler(tier: .export, modelURL:)`. The `tileSize` and
    /// `tileOverlap` parameters are accepted for source-compat with the
    /// pre-Phase-D signature but ignored — the tier picks the right shape
    /// for its model.
    public convenience init(
        modelURL: URL,
        scale: Int = 4,
        tileSize: Int = 128,
        tileOverlap: Int = 16
    ) throws {
        // Silence unused-parameter warnings while preserving the call-site
        // signature. The tier reports its own tile shape via `inputTileSize`.
        _ = tileSize
        _ = tileOverlap
        let tier = try RealESRGAN_CoreML(modelURL: modelURL, scale: scale)
        self.init(tier: tier)
    }

    // MARK: - Inference

    /// Upscale a single frame using the active tier.
    ///
    /// `ExportTier.upscale(_:)` is async to leave room for future diffusion /
    /// MLX backends that run on their own queues. The CoreML tier is
    /// synchronous-under-the-hood, so we block the calling thread on a
    /// semaphore for the result. This preserves the existing synchronous
    /// call-site signature in `ExportPipeline.processVideo` (out of scope
    /// to change in Phase D per the task brief).
    public func upscale(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
        // `CVPixelBuffer` is a CoreFoundation reference type and not formally
        // `Sendable`. We pass it through an `UnsafeBufferBox` to express
        // that the calling thread blocks on the semaphore for the duration
        // of the detached task — no concurrent access to `input` occurs.
        let box = UnsafeBufferBox(input)
        let tierRef = tier
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<CVPixelBuffer, Error> =
            .failure(ExportTierError.inferenceFailed("uninitialised"))
        Task.detached {
            do {
                let out = try await tierRef.upscale(box.buffer)
                result = .success(out)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    /// Sendable wrapper for `CVPixelBuffer`. Marked `@unchecked Sendable`
    /// because callers must guarantee no concurrent access — `upscale(_:)`
    /// blocks on a semaphore around the only crossing point.
    private struct UnsafeBufferBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
        init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
    }
}
