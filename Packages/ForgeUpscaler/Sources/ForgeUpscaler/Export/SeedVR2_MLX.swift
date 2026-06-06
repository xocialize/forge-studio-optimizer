// SeedVR2_MLX.swift
//
// Role: Native-MLX `ExportTier` backed by SeedVR2-3B (ByteDance, ICLR 2026,
//       Apache-2.0) — one-step diffusion super-resolution. This is the
//       working replacement for the `OSEDiff_MLX` stub (ADR-0007's revisit
//       trigger: "swap to a native MLX backend"). SeedVR2 *is* one-step
//       diffusion SR, with permissive (Apache) weights published to
//       `mlx-community/SeedVR2-3B-mlx{,-int8}`.
//
// Mechanism (matches the mflux reference): SeedVR2 doesn't change spatial size
// (VAE encode 8× down → DiT → decode 8× up = identity). The spatial upscale is
// a **bicubic/Lanczos pre-upscale** (CoreImage, host); SeedVR2 then **refines**
// the upscaled image via a single diffusion step. So:
//   1. CoreImage Lanczos upscale the input by `scaleFactor`.
//   2. Refine at 1:1 via `MLXTileProcessor` (scale = 1), tile-blended.
//
// Model package: `SeedVR2MLX` (github.com/xocialize/seedvr2-mlx-swift) — the
// DiT + 3D-VAE + 1-step loop, parity-verified vs mflux. Weights (~4 GB int8)
// are NOT bundled; load from a local dir or HF repo id (first-run download).
//
// Tile shape: 256×256 (multiple of 16 — SeedVR2's VAE needs dims % 16), 32 px
// overlap (Plan §D.2). Run on the GPU stream for throughput.

import CoreImage
import CoreVideo
import Foundation
import MLX
import SeedVR2MLX

/// SeedVR2 one-step diffusion SR export tier (native MLX).
public final class SeedVR2_MLX: ExportTier, @unchecked Sendable {

    public let name: String = "seedvr2-mlx"
    public let scaleFactor: Int
    public let inputTileSize: Int
    public let tileOverlap: Int
    public var inputResolution: (width: Int, height: Int) { (inputTileSize, inputTileSize) }
    public var outputResolution: (width: Int, height: Int) { (inputTileSize * scaleFactor, inputTileSize * scaleFactor) }

    private let upscaler: SeedVR2Upscaler
    private let seed: UInt64
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Load from a local weights directory (transformer/vae/pos_emb/config).
    public init(weightsDirectory: URL, scale: Int = 2, tileSize: Int = 256, tileOverlap: Int = 32, seed: UInt64 = 42) throws {
        guard scale == 2 || scale == 4 else { throw ExportTierError.unsupportedScale(scale) }
        precondition(tileSize % 16 == 0, "SeedVR2 tile size must be a multiple of 16")
        do { self.upscaler = try SeedVR2Upscaler(directory: weightsDirectory) }
        catch { throw ExportTierError.modelLoadFailed("SeedVR2 weights at \(weightsDirectory.path): \(error)") }
        self.scaleFactor = scale; self.inputTileSize = tileSize; self.tileOverlap = tileOverlap; self.seed = seed
    }

    /// Download (first run) + load from an HF repo id (default: published int8).
    public init(repoId: String = "mlx-community/SeedVR2-3B-mlx-int8", scale: Int = 2,
                tileSize: Int = 256, tileOverlap: Int = 32, seed: UInt64 = 42) throws {
        guard scale == 2 || scale == 4 else { throw ExportTierError.unsupportedScale(scale) }
        precondition(tileSize % 16 == 0, "SeedVR2 tile size must be a multiple of 16")
        do { self.upscaler = try SeedVR2Upscaler(repoId: repoId) }
        catch { throw ExportTierError.modelLoadFailed("SeedVR2 repo \(repoId): \(error)") }
        self.scaleFactor = scale; self.inputTileSize = tileSize; self.tileOverlap = tileOverlap; self.seed = seed
    }

    public func upscale(_ buffer: CVPixelBuffer) async throws -> CVPixelBuffer {
        // 1. Lanczos pre-upscale (the spatial SR); SeedVR2 then refines at 1:1.
        let upsized = try lanczosUpscale(buffer, factor: scaleFactor)

        // 2. Refine each tile through SeedVR2 (scale = 1; the buffer is already scaled).
        let tiler = MLXTileProcessor(tileSize: inputTileSize, overlap: tileOverlap, scale: 1)
        let seedRef = seed, model = upscaler
        return try tiler.process(upsized) { tile in
            // tile: [1, th, tw, 3] NHWC RGB in [0,1]  ->  [-1,1] NCHW  -> refine -> [0,1] NHWC
            let nchw = tile.transposed(0, 3, 1, 2) * 2 - 1
            var out = model.upscale(processedImage: nchw, seed: seedRef)   // [1,3,1,th,tw]
            if out.ndim == 5 { out = out[0..., 0..., 0] }                  // [1,3,th,tw]
            out = clip((out + 1) * 0.5, min: 0, max: 1)
            return out.transposed(0, 2, 3, 1)                              // [1,th,tw,3]
        }
    }

    /// CoreImage Lanczos upscale of a CVPixelBuffer by an integer factor.
    private func lanczosUpscale(_ input: CVPixelBuffer, factor: Int) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        let (ow, oh) = (w * factor, h * factor)
        let ci = CIImage(cvPixelBuffer: input)
        let scaled = ci.applyingFilter("CILanczosScaleTransform",
                                       parameters: [kCIInputScaleKey: Double(factor), kCIInputAspectRatioKey: 1.0])
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: ow, kCVPixelBufferHeightKey as String: oh,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(nil, ow, oh, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let outBuffer = out else {
            throw ExportTierError.modelLoadFailed("CVPixelBufferCreate failed for \(ow)x\(oh)")
        }
        // Render the (origin-shifted) scaled image into the output buffer.
        ciContext.render(scaled, to: outBuffer)
        return outBuffer
    }
}
