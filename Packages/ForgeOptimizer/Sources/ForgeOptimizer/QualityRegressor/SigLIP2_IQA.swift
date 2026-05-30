//
//  SigLIP2_IQA.swift
//  ForgeOptimizer / QualityRegressor
//
//  Role: NR-IQA (No-Reference Image Quality Assessment) head atop the SigLIP2
//        vision backbone. A 2-layer MLP that maps the 768-d mean-pooled patch
//        embedding to a scalar quality score in [0, 1].
//
//  Plan ref: Forge-CodingPlan-v1.0.md §E.2 / Task #27 (Phase E.2c)
//  Paper:    arXiv:2509.17374v2 "Lightweight NR-IQA via SigLIP2 features"
//            (head ablation: Swish vs GELU mid-activation; both within noise.
//             We pick GELU for consistency with SigLIP2's own activation,
//             keeping the whole chain in one activation family.)
//
//  Conventions:
//    - NHWC (irrelevant here — head input is [B, 768], 1-D after pooling)
//    - `@unchecked Sendable` because MLX state isn't Sendable
//    - Public init lets callers vary `hiddenDim` if a future head-size sweep
//      lands in Phase E.4; default = 256 per the paper.
//
//  Training is Phase E.4. This file ships the architecture only.
//

import Foundation
import MLX
import MLXNN

// MARK: - NR-IQA Head

/// Two-layer MLP head: `[B, embeddingDim] → [B, hiddenDim] (GELU) → [B, 1] (sigmoid → [0, 1])`.
///
/// Parameter count at the default 768 → 256 → 1 config:
///   - fc1: 768 × 256 + 256 = 196,864
///   - fc2: 256 × 1 + 1 = 257
///   - total ≈ 197,121 (~0.2 M params, ~0.4 MB FP16)
///
/// Sigmoid output keeps the score in `[0, 1]`. The Phase E.4 training loop
/// will (a) rescale KonIQ-10k MOS labels to `[0, 1]` and (b) use a regression
/// loss against this output. Until trained, the head emits ~0.5 for any
/// input — useful only as an architectural smoke test.
public final class SigLIP2_IQA: Module, @unchecked Sendable {

    @ModuleInfo public var fc1: Linear
    @ModuleInfo public var fc2: Linear

    public let embeddingDim: Int
    public let hiddenDim: Int

    public init(embeddingDim: Int = 768, hiddenDim: Int = 256) {
        self.embeddingDim = embeddingDim
        self.hiddenDim = hiddenDim
        self._fc1.wrappedValue = Linear(embeddingDim, hiddenDim, bias: true)
        self._fc2.wrappedValue = Linear(hiddenDim, 1, bias: true)
    }

    /// Forward.
    /// - Parameter embedding: `[B, embeddingDim]` mean-pooled SigLIP2 vision
    ///   feature.
    /// - Returns: `[B, 1]` predicted quality score in `[0, 1]`.
    public func callAsFunction(_ embedding: MLXArray) -> MLXArray {
        // GELU between layers. Sigmoid at the head clamps to [0, 1].
        // `gelu` (erf) is fine here even though SigLIP2 uses
        // `geluApproximate` (tanh) — the head is trained fresh in Phase
        // E.4, so the activation choice is a free knob, not a
        // weight-matching constraint. We pick standard `gelu` because
        // the upstream NR-IQA papers' "GELU head" baseline used the
        // exact-erf variant.
        let h = MLXNN.gelu(fc1(embedding))
        let logit = fc2(h)
        return MLX.sigmoid(logit)
    }
}

// MARK: - QualityScorer convenience

/// Convenience: SigLIP2 backbone + NR-IQA head + a `score(_:)` method that
/// takes raw pixel values and returns a scalar quality score.
///
/// This is the type that Phase E.5 will register with `ModelRegistry` and
/// expose to `BenchmarkSuite.QualityMeasure`. For Phase E.2 it just exists
/// so the architecture sandwich is end-to-end runnable.
///
/// Both child modules use `@ModuleInfo` so MLX-Swift's `Module` machinery
/// can recursively flatten / load parameters under the `backbone.*` and
/// `head.*` key prefixes. Phase E.4 training will save under those prefixes;
/// loadWeights wiring is left for Phase E.5 since head + backbone come from
/// different sources (lazy-downloaded vs locally trained).
public final class SigLIP2QualityScorer: Module, @unchecked Sendable {

    @ModuleInfo public var backbone: SigLIP2VisionModel
    @ModuleInfo public var head: SigLIP2_IQA

    public init(
        backbone: SigLIP2VisionModel = SigLIP2VisionModel(),
        head: SigLIP2_IQA = SigLIP2_IQA()
    ) {
        self._backbone.wrappedValue = backbone
        self._head.wrappedValue = head
    }

    /// End-to-end: pixels → embedding → score.
    /// - Parameter pixelValues: `[B, H, W, 3]` NHWC at the backbone's
    ///   `imageSize` (224 for the base config). Value range: per-channel
    ///   `mean=0.5, std=0.5` normalization, i.e. roughly `[-1, +1]` floats.
    /// - Returns: `[B, 1]` scalar quality score in `[0, 1]`.
    public func score(_ pixelValues: MLXArray) -> MLXArray {
        let embedding = backbone(pixelValues).poolerOutput
        let s = head(embedding)
        MLX.eval(s)
        return s
    }
}
