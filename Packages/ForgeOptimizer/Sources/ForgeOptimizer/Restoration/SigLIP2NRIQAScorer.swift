//
//  SigLIP2NRIQAScorer.swift
//  ForgeOptimizer / Restoration
//
//  The learned NR-IQA gate signal (Step 3, #51 / #56, ADR-0016): the trained
//  SigLIP2 v2 head over the dequantized 8-bit backbone (#57, parity cosine
//  0.9999 vs FP). Estimates a frame's perceptual quality in [0,1] (1 = pristine)
//  by mean-pooling the head's score over native-scale 224 patches — the
//  "does-restoration-pay" signal that gates NAFNet. Replaces the interim
//  `BlockinessQualityScorer` as the default gate scorer.
//
//  Conventions: SigLIP2 expects NHWC, 224², per-channel mean/std = 0.5 (i.e.
//  [0,1] → [-1,1]). `poolerOutput` is already mean-pool (the MAP head is skipped),
//  matching how the head was trained. `@unchecked Sendable` + a lock around the
//  MLX forward (MLX state isn't Sendable; the gate may be hit from a decode loop).
//

import CoreImage
import CoreVideo
import Foundation
import MLX
import MLXNN

public final class SigLIP2NRIQAScorer: NoReferenceQualityScoring, @unchecked Sendable {

    private let scorer: SigLIP2QualityScorer
    private let lock = NSLock()
    private let patchSize: Int
    private let maxPatches: Int
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// - Parameters:
    ///   - backboneWeightsURL: cached mlx-community 8-bit safetensors
    ///     (`SigLIP2BackboneLoader` cache).
    ///   - headWeightsURL: trained NR-IQA head safetensors (keys fc1/fc2.weight+bias).
    ///   - maxPatches: native-scale 224 crops to average per frame (grid-sampled).
    public init(backboneWeightsURL: URL, headWeightsURL: URL,
                patchSize: Int = 224, maxPatches: Int = 8) throws {
        let backbone = SigLIP2VisionModel()
        try backbone.loadWeights(from: backboneWeightsURL)

        let head = SigLIP2_IQA()
        let headArrays = try MLX.loadArrays(url: headWeightsURL)
        try head.update(parameters: ModuleParameters.unflattened(headArrays), verify: .all)
        MLX.eval(head.parameters())

        self.scorer = SigLIP2QualityScorer(backbone: backbone, head: head)
        self.patchSize = patchSize
        self.maxPatches = maxPatches
    }

    /// Resolve from the standard ship locations: the cached 8-bit backbone
    /// (`SigLIP2BackboneLoader` — `ensureWeights()` must have run, e.g. at app
    /// startup; it's a ~400 MB lazy download, ADR-0005) + the bundled head
    /// (`Bundle.module`). Throws if either is absent — `makeGatedChain` catches
    /// that and falls back to unconditional NAFNet.
    public convenience init(maxPatches: Int = 8) throws {
        let backbone = SigLIP2BackboneLoader.defaultCacheRoot.appending(path: "model.safetensors")
        guard FileManager.default.fileExists(atPath: backbone.path) else {
            throw ForgeOptimizerError.modelLoadFailed(
                "SigLIP2 backbone not cached — run SigLIP2BackboneLoader.ensureWeights() at startup")
        }
        guard let head = Bundle.module.url(forResource: "siglip2_iqa_head", withExtension: "safetensors") else {
            throw ForgeOptimizerError.modelLoadFailed(
                "siglip2_iqa_head.safetensors not in Bundle.module (vendor it into ForgeOptimizer/Resources/)")
        }
        try self.init(backboneWeightsURL: backbone, headWeightsURL: head, maxPatches: maxPatches)
    }

    public func quality(_ pixelBuffer: CVPixelBuffer) -> Float {
        lock.lock(); defer { lock.unlock() }
        // Fail OPEN (return pristine → skip restoration) on any preprocessing
        // failure, so a single bad frame never forces a wrong "degraded" verdict.
        guard let patches = patchTensor(pixelBuffer) else { return 1.0 }
        let norm = patches * 2.0 - 1.0                 // [0,1] → [-1,1] (mean/std 0.5)
        let scores = scorer.score(norm)                // [K, 1]
        let mean = MLX.mean(scores)
        MLX.eval(mean)
        return mean.item(Float.self)
    }

    // MARK: - Preprocessing

    /// → `[K, ps, ps, 3]` RGB in [0,1]: native-scale grid crops when the frame is
    /// ≥ ps in both dims; otherwise a single CoreImage-downscaled `ps×ps` patch.
    private func patchTensor(_ pixelBuffer: CVPixelBuffer) -> MLXArray? {
        let bgra = ensureBGRA(pixelBuffer)
        let w = CVPixelBufferGetWidth(bgra)
        let h = CVPixelBufferGetHeight(bgra)
        let ps = patchSize

        if h < ps || w < ps {
            guard let scaled = resizedBGRA(bgra, to: ps),
                  let one = NAFNetProcessor.rgbNHWC(from: scaled, width: ps, height: ps)
            else { return nil }
            return one
        }

        guard let full = NAFNetProcessor.rgbNHWC(from: bgra, width: w, height: h) else { return nil }
        var crops: [MLXArray] = []
        for (y, x) in gridPositions(h: h, w: w, ps: ps) {
            let cropY = full[y ..< (y + ps), axis: 1]      // [1, ps, W, 3]
            crops.append(cropY[x ..< (x + ps), axis: 2])   // [1, ps, ps, 3]
        }
        return crops.count == 1 ? crops[0] : MLX.concatenated(crops, axis: 0)
    }

    /// Evenly-spaced top-left corners of a near-square grid, capped at `maxPatches`.
    private func gridPositions(h: Int, w: Int, ps: Int) -> [(Int, Int)] {
        let n = max(1, Int(Double(maxPatches).squareRoot().rounded()))
        let rows = min(n, max(1, h / ps))
        let cols = min(n, max(1, w / ps))
        func spaced(_ count: Int, _ span: Int) -> [Int] {
            if count <= 1 { return [span / 2] }            // center
            return (0 ..< count).map { ($0 * span) / (count - 1) }   // 0…span inclusive
        }
        let ys = spaced(rows, h - ps)
        let xs = spaced(cols, w - ps)
        var pos: [(Int, Int)] = []
        for y in ys {
            for x in xs {
                pos.append((y, x))
                if pos.count >= maxPatches { return pos }
            }
        }
        return pos
    }

    /// Lanczos-ish downscale a BGRA buffer to `size × size` (small-frame fallback).
    private func resizedBGRA(_ src: CVPixelBuffer, to size: Int) -> CVPixelBuffer? {
        let ci = CIImage(cvPixelBuffer: src)
        let sx = CGFloat(size) / CGFloat(CVPixelBufferGetWidth(src))
        let sy = CGFloat(size) / CGFloat(CVPixelBufferGetHeight(src))
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &out) == kCVReturnSuccess,
              let buf = out else { return nil }
        ciContext.render(scaled, to: buf)
        return buf
    }
}
