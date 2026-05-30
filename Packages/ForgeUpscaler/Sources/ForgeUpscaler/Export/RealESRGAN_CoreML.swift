// RealESRGAN_CoreML.swift
//
// Role: Concrete `ExportTier` backed by the vendored Real-ESRGAN RRDBNet
//       CoreML packages at `Sources/ForgeUpscaler/Resources/realesrgan_x{2,4}.mlpackage`.
//       The mlpackages were vendored in Phase 0.D from
//       `xocialize-code/com.xocialize.coreml@3989123` (BSD-3-Clause).
//
// Plan reference: Docs/Forge-CodingPlan-v1.0.md §D.1, §D.2
// ADR:           Docs/ADRs/0007-real-esrgan-export-tier.md (chose this over
//                the themindstudio/RealESRGAN-x4plus-mlx port — no Swift
//                loader exists for the upstream `.npz`).
// Licenses:      Packages/ForgeUpscaler/LICENSES.md §"Phase D — Export tier"
//
// Tile shape note (Plan §D.2 calls for 256/32):
//   The vendored mlpackage has a *fixed* 128×128 CHW input shape (see
//   Resources/MODELS.md). Feeding 256×256 to the CoreML model would fail at
//   prediction time. We use 128×128 tiles with 16 px overlap — same numbers
//   `PlaybackUpscaler` uses against the (different-architecture) SRVGGNet
//   path, which is the right shape for this model. ADR-0007 documents the
//   deviation. A future swap to a flexible-input MLX backend can move to
//   256/32 by overriding `inputTileSize` / `tileOverlap`.

import CoreML
import CoreVideo
import Foundation

/// Real-ESRGAN RRDBNet export tier backed by CoreML.
///
/// Loads `realesrgan_x2.mlpackage` (2× scale) or `realesrgan_x4.mlpackage`
/// (4× scale) from the bundle, compiles on first init, and runs the existing
/// `TileProcessor` for full-frame inference.
///
/// Marked `@unchecked Sendable` because `MLModel` is not formally Sendable;
/// the surrounding code treats the model as read-only after init, which is
/// the same convention `PlaybackUpscaler` follows.
public final class RealESRGAN_CoreML: ExportTier, @unchecked Sendable {

    // MARK: - ExportTier surface

    public let name: String = "real-esrgan-coreml"
    public let scaleFactor: Int
    public let inputTileSize: Int
    public let tileOverlap: Int

    public var inputResolution: (width: Int, height: Int) {
        (inputTileSize, inputTileSize)
    }

    public var outputResolution: (width: Int, height: Int) {
        (inputTileSize * scaleFactor, inputTileSize * scaleFactor)
    }

    // MARK: - Internals

    private let model: MLModel
    private let tileProcessor: TileProcessor

    // MARK: - Init

    /// Initialise from a content preset using the vendored mlpackages.
    ///
    /// `preset: .anime` resolves to the general weights for now — anime-specific
    /// Real-ESRGAN weights are future work (see Forge-CodingPlan-v1.0.md §F /
    /// ForgeUpscaler-PRD-v0.1.md §4.4).
    ///
    /// - Parameters:
    ///   - preset: Content hint; `.anime` reuses `.general` weights today.
    ///   - scale: 2 or 4. Anything else throws `.unsupportedScale`.
    ///   - computeUnits: CoreML compute selection; defaults to `.all` to use
    ///     the GPU + Neural Engine for export throughput.
    public convenience init(
        preset: ForgeUpscaler.ContentPreset = .general,
        scale: Int = 4,
        computeUnits: MLComputeUnits = .all
    ) throws {
        let modelName: String
        switch scale {
        case 2: modelName = "realesrgan_x2"
        case 4: modelName = "realesrgan_x4"
        default: throw ExportTierError.unsupportedScale(scale)
        }
        // Note `preset` is accepted for API parity with PlaybackUpscaler /
        // ExportUpscaler; today every preset resolves to the general weights.
        _ = preset

        guard let modelURL = Bundle.module.url(forResource: modelName, withExtension: "mlpackage") else {
            throw ExportTierError.modelLoadFailed("Bundle.module missing \(modelName).mlpackage")
        }
        try self.init(modelURL: modelURL, scale: scale, computeUnits: computeUnits)
    }

    /// Initialise from an explicit `.mlpackage` URL. Used by tests and by
    /// callers that want to point at a side-loaded model.
    public init(
        modelURL: URL,
        scale: Int = 4,
        computeUnits: MLComputeUnits = .all
    ) throws {
        guard scale == 2 || scale == 4 else {
            throw ExportTierError.unsupportedScale(scale)
        }
        self.scaleFactor = scale
        // The vendored mlpackages are fixed at 128×128 input. Mirrored
        // overlap (16 px) is the same `PlaybackUpscaler` uses against
        // the SRVGGNet path — gives clean seams without ballooning tile
        // count on 1080p inputs.
        self.inputTileSize = 128
        self.tileOverlap = 16

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        do {
            let compiledURL = try MLModel.compileModel(at: modelURL)
            self.model = try MLModel(contentsOf: compiledURL, configuration: config)
        } catch {
            throw ExportTierError.modelLoadFailed(
                "compile/load failed for \(modelURL.lastPathComponent): \(error)"
            )
        }

        self.tileProcessor = TileProcessor(
            tileSize: inputTileSize,
            overlap: tileOverlap,
            scale: scale
        )
    }

    // MARK: - ExportTier impl

    public func upscale(_ buffer: CVPixelBuffer) async throws -> CVPixelBuffer {
        do {
            return try tileProcessor.process(buffer, model: model)
        } catch let err as UpscalerError {
            // Re-shape playback-tier errors as export-tier errors so callers
            // get a consistent surface.
            throw ExportTierError.inferenceFailed("\(err)")
        } catch {
            throw ExportTierError.inferenceFailed("\(error)")
        }
    }
}
