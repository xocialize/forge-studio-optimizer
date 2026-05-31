//
//  NAFNetProcessor.swift
//  ForgeOptimizer / Restoration
//
//  Role: FrameProcessor adapter that runs the trained MLX NAFNet restoration
//        model over a decoded video frame. Replaces the v0.3 256²-resize
//        Denoiser + ArtifactRemover stub chain with one full-resolution model
//        (Phase B.5 / Task #14).
//
//  Pipeline contract (FormatBridge.FrameProcessor):
//      process(CVPixelBuffer) -> CVPixelBuffer   (same resolution in/out)
//
//  Conventions:
//    - NAFNet was trained on RGB PNG tiles in [0, 1] (Phase B.2 corpus), so the
//      frame is fed as RGB float32 [0, 1], NHWC [1, H, W, 3].
//    - NV12 hazard: FFmpegDecoder emits biplanar NV12. The byte reader below
//      assumes packed BGRA, so we `ensureBGRA` first (CoreImage YCbCr→RGB) —
//      else the model restores sheared luma garbage. Same defect class as the
//      ForgeUpscaler playback tier (commit e06ff85) and the optimizer CoreML
//      path (12dbb83).
//    - NAFNet is fully convolutional and pads/crops internally, so any
//      resolution is accepted (no 256² resize, unlike the v0.3 stubs).
//

import CoreVideo
import Foundation
import FormatBridge
import MLX

/// Runs the trained NAFNet restoration model over each frame.
public final class NAFNetProcessor: FrameProcessor, @unchecked Sendable {

    private let model: NAFNet
    /// MLX GPU state is not thread-safe; serialize `process` calls.
    private let lock = NSLock()

    /// Load NAFNet with the bundled weights (`nafnet.safetensors`, Phase B.4).
    /// The architecture is the ADR-0003 default (width 24, [1,1,1,1]) — matches
    /// the trained checkpoint.
    public init() throws {
        let model = NAFNet()
        guard let url = Bundle.module.url(forResource: "nafnet", withExtension: "safetensors") else {
            throw ForgeOptimizerError.modelLoadFailed(
                "nafnet.safetensors not found in Bundle.module (vendor it into ForgeOptimizer/Resources/)")
        }
        try model.loadWeights(from: url)
        self.model = model
    }

    /// Restore one frame. On any failure the input is returned unchanged so the
    /// conversion pipeline never stalls on a single bad frame.
    public func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        lock.lock()
        defer { lock.unlock() }

        let bgra = ensureBGRA(pixelBuffer)
        let width = CVPixelBufferGetWidth(bgra)
        let height = CVPixelBufferGetHeight(bgra)
        guard let input = Self.rgbNHWC(from: bgra, width: width, height: height) else {
            return pixelBuffer
        }
        // Run in fp16 end-to-end. The vendored weights are fp16; an fp32 input
        // would force MLX to promote the entire forward to fp32 (≈2× slower,
        // ≈2× peak memory — the latter matters for 4K on a 16 GB M1). fp16
        // compute is plenty for an 8-bit-output restoration model (parity vs
        // fp32 stays ~3e-3).
        let output = model(input.asType(.float16))
        MLX.eval(output)
        guard let out = Self.pixelBuffer(fromRGBNHWC: output, width: width, height: height) else {
            return pixelBuffer
        }
        return out
    }

    // MARK: - Pixel ↔ MLX (RGB [0,1] NHWC)

    /// BGRA `CVPixelBuffer` → `[1, H, W, 3]` RGB float32 in [0, 1].
    static func rgbNHWC(from bgra: CVPixelBuffer, width: Int, height: Int) -> MLXArray? {
        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(bgra) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(bgra)
        let src = base.assumingMemoryBound(to: UInt8.self)

        var rgb = [Float](repeating: 0, count: height * width * 3)
        for y in 0 ..< height {
            let row = y * bytesPerRow
            let drow = y * width * 3
            for x in 0 ..< width {
                let s = row + x * 4
                let d = drow + x * 3
                rgb[d + 0] = Float(src[s + 2]) / 255.0  // R  (BGRA byte 2)
                rgb[d + 1] = Float(src[s + 1]) / 255.0  // G
                rgb[d + 2] = Float(src[s + 0]) / 255.0  // B
            }
        }
        return MLXArray(rgb, [1, height, width, 3])
    }

    /// `[1, H, W, 3]` RGB float (any range; clamped) → BGRA `CVPixelBuffer`.
    static func pixelBuffer(fromRGBNHWC array: MLXArray, width: Int, height: Int) -> CVPixelBuffer? {
        let rgb = array.asArray(Float.self)
        guard rgb.count >= width * height * 3 else { return nil }

        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let dstBase = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        @inline(__always) func clamp(_ v: Float) -> UInt8 {
            UInt8(max(0, min(255, v * 255)))
        }
        for y in 0 ..< height {
            let row = y * bytesPerRow
            let srow = y * width * 3
            for x in 0 ..< width {
                let d = row + x * 4
                let s = srow + x * 3
                dst[d + 0] = clamp(rgb[s + 2])  // B
                dst[d + 1] = clamp(rgb[s + 1])  // G
                dst[d + 2] = clamp(rgb[s + 0])  // R
                dst[d + 3] = 255
            }
        }
        return buffer
    }
}
