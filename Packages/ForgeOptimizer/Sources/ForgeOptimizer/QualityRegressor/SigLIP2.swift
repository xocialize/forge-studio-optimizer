//
//  SigLIP2.swift
//  ForgeOptimizer / QualityRegressor
//
//  Role: MLX-Swift port of the SigLIP2 vision encoder (image side only).
//        Provides patch embeddings, a 12-layer Transformer encoder, and a
//        mean-pooled output for downstream NR-IQA. The text encoder is
//        intentionally NOT ported — Phase E.2 IQA is image-only.
//
//  Plan ref: Forge-CodingPlan-v1.0.md §E.2 / Task #27 (Phase E.2b)
//  ADR:      Docs/ADRs/0005-siglip2-lazy-download.md (weights are
//            lazy-downloaded by SigLIP2BackboneLoader, NOT vendored)
//
//  Upstream PyTorch reference (transformers main, 2026-05-28):
//    Class:  Siglip2VisionModel / Siglip2VisionTransformer
//    File:   src/transformers/models/siglip2/modeling_siglip2.py
//    Config: Siglip2VisionConfig — base-patch16-224 defaults:
//              hidden_size=768, num_hidden_layers=12, num_attention_heads=12,
//              intermediate_size=3072, image_size=224, patch_size=16,
//              num_channels=3, hidden_act="gelu_pytorch_tanh",
//              layer_norm_eps=1e-6, attention_dropout=0.0
//            (verified against MLX-community config.json on 2026-05-28.)
//
//  Architecture discoveries (per mlx-porting skill pitfall #6 —
//  "non-obvious flags"):
//    - Activation is "gelu_pytorch_tanh" — i.e. the `tanh`-approximate GELU
//      variant. In MLX-Swift this is `geluApproximate(_:)` (NOT plain `gelu`).
//      Standard `gelu` would diverge against pretrained weights at the MLP
//      step; safe for now (E.4 trains the head only, backbone is frozen) but
//      worth nailing now because Phase E.5's QualityMeasure integration will
//      consume real pretrained activations.
//    - No CLS token — vision model emits patch tokens only.
//    - No QK norm, no RoPE — standard ViT pre-LN with learned absolute pos
//      embeddings (`nn.Embedding(num_patches, hidden_size)`).
//    - Upstream uses a Multihead Attention Pooling head ("MAP") with a
//      learnable `probe` parameter for the pooled output. The Phase E.2
//      task brief asks for mean-pool over patch tokens for the IQA head
//      input. We implement BOTH — `Output.poolerOutput` is mean-pool (matches
//      the brief and is what the NR-IQA head wants) and we leave a TODO for
//      Phase E.5 to swap in the MAP head if the pretrained weights' pooler
//      output is needed for downstream tasks (text-image similarity, etc).
//      The MAP-head safetensors keys are skipped on load with .ignoreUnused.
//    - `post_layernorm` after the encoder stack — this IS implemented,
//      because it's part of the patch-token output the IQA head sees.
//
//  Conventions:
//    - NHWC tensor layout (MLX-Swift default; matches CLAUDE.md)
//    - `@unchecked Sendable` for classes that hold MLX state
//    - MLXFast.scaledDotProductAttention for the attention block (per
//      mlx-swift skill — avoids hand-rolling QK^T/√d, which is also a
//      frequent source of pitfall #5 norm/eps drift)
//    - Weight loading uses the standard MLX.loadArrays → ModuleParameters
//      .unflattened → Module.update pipeline (see NAFNet.swift)
//

import Foundation
import MLX
import MLXNN
import MLXFast

// MARK: - Vision Embeddings

/// Convert 224×224×3 pixel values into a sequence of 196 patch tokens with
/// added learned absolute position embeddings.
///
/// Upstream `SiglipVisionEmbeddings` (`siglip` v1 layout — SigLIP2's
/// base-patch16-224 inherits the same patch-embedding shape; the dynamic
/// NaFlex variant is a different model class).
///
/// PyTorch reference:
/// ```
/// patch_embedding = nn.Conv2d(num_channels, embed_dim,
///                             kernel_size=patch_size, stride=patch_size,
///                             padding="valid")
/// num_patches = (image_size // patch_size) ** 2  # = 196
/// position_embedding = nn.Embedding(num_patches, embed_dim)
/// position_ids = arange(num_patches).expand((1, -1))
///
/// def forward(pixel_values):
///     patch_embeds = patch_embedding(pixel_values)        # [B, D, 14, 14]
///     embeddings = patch_embeds.flatten(2).transpose(1,2) # [B, 196, D]
///     return embeddings + position_embedding(position_ids)
/// ```
///
/// NHWC port:
///   - `patch_embedding` is MLX Conv2d (input NHWC = `[B, 224, 224, 3]`) with
///     kernel=patch_size, stride=patch_size, padding=0. Output shape is
///     `[B, 14, 14, 768]` — directly reshapeable to `[B, 196, 768]` without
///     a transpose. (The PyTorch flatten(2).transpose(1,2) chain is needed
///     because NCHW emits `[B, D, H, W]`; NHWC already has the channel last.)
///   - `position_embedding` is MLXNN.Embedding(196, 768) for the standard
///     224×224 / patch16 config. Index lookup via `[0..<196]`.
final class SigLIP2VisionEmbeddings: Module, @unchecked Sendable {

    @ModuleInfo(key: "patch_embedding") var patchEmbedding: Conv2d
    @ModuleInfo(key: "position_embedding") var positionEmbedding: Embedding

    let imageSize: Int
    let patchSize: Int
    let numPatches: Int
    let embedDim: Int

    init(
        hiddenSize: Int = 768,
        imageSize: Int = 224,
        patchSize: Int = 16,
        numChannels: Int = 3
    ) {
        precondition(imageSize % patchSize == 0,
                     "image_size (\(imageSize)) must be divisible by patch_size (\(patchSize))")
        self.imageSize = imageSize
        self.patchSize = patchSize
        self.embedDim = hiddenSize
        self.numPatches = (imageSize / patchSize) * (imageSize / patchSize)

        // Conv2d in MLX-Swift takes (in, out, kernel, stride, padding) with
        // weight layout [out, kH, kW, in] — the MLX standard NHWC layout.
        // padding="valid" in PyTorch == padding=0 in MLX.
        self._patchEmbedding.wrappedValue = Conv2d(
            inputChannels: numChannels,
            outputChannels: hiddenSize,
            kernelSize: .init(patchSize),
            stride: .init(patchSize),
            padding: .init(0),
            bias: true
        )

        self._positionEmbedding.wrappedValue = Embedding(
            embeddingCount: numPatches,
            dimensions: hiddenSize
        )
    }

    /// Forward.
    /// - Parameter pixelValues: `[B, imageSize, imageSize, numChannels]` NHWC.
    /// - Returns: `[B, numPatches, hiddenSize]` patch tokens with positional
    ///   embeddings added.
    func callAsFunction(_ pixelValues: MLXArray) -> MLXArray {
        // Patch embed: [B, 224, 224, 3] → [B, 14, 14, 768]
        let patches = patchEmbedding(pixelValues)
        let s = patches.shape
        let B = s[0]
        // Flatten the two spatial axes: [B, 14, 14, 768] → [B, 196, 768]
        let flat = patches.reshaped([B, numPatches, embedDim])

        // Position embedding lookup. position_ids = arange(num_patches).
        // The Embedding.callAsFunction does the lookup; passing a 1-D index
        // returns a [num_patches, embed_dim] tensor which broadcasts cleanly
        // over the leading batch axis.
        let posIds = MLXArray(0 ..< Int32(numPatches))
        let posEmbeds = positionEmbedding(posIds)  // [num_patches, embed_dim]

        return flat + posEmbeds
    }
}

// MARK: - Attention

/// Multi-head self-attention block.
///
/// PyTorch reference:
/// ```
/// q_proj = nn.Linear(embed_dim, embed_dim)
/// k_proj = nn.Linear(embed_dim, embed_dim)
/// v_proj = nn.Linear(embed_dim, embed_dim)
/// out_proj = nn.Linear(embed_dim, embed_dim)
/// scale = head_dim ** -0.5  # 1/sqrt(64) for base
/// is_causal = False
///
/// def forward(hidden_states):
///     q = q_proj(hidden_states).view(B, T, num_heads, head_dim).transpose(1, 2)
///     k = k_proj(hidden_states).view(B, T, num_heads, head_dim).transpose(1, 2)
///     v = v_proj(hidden_states).view(B, T, num_heads, head_dim).transpose(1, 2)
///     out = scaled_dot_product_attention(q, k, v, scale=scale, is_causal=False)
///     out = out.transpose(1, 2).reshape(B, T, embed_dim)
///     return out_proj(out)
/// ```
///
/// MLX-Swift port uses `MLXFast.scaledDotProductAttention` (Apple-Silicon-
/// optimized) per the mlx-swift skill recommendation. No QK norm.
final class SigLIP2Attention: Module, @unchecked Sendable {

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    let numHeads: Int
    let headDim: Int
    let scale: Float

    init(hiddenSize: Int, numAttentionHeads: Int) {
        precondition(hiddenSize % numAttentionHeads == 0,
                     "hidden_size (\(hiddenSize)) must be divisible by num_attention_heads (\(numAttentionHeads))")
        self.numHeads = numAttentionHeads
        self.headDim = hiddenSize / numAttentionHeads
        self.scale = 1.0 / Float(headDim).squareRoot()

        self._qProj.wrappedValue = Linear(hiddenSize, hiddenSize, bias: true)
        self._kProj.wrappedValue = Linear(hiddenSize, hiddenSize, bias: true)
        self._vProj.wrappedValue = Linear(hiddenSize, hiddenSize, bias: true)
        self._outProj.wrappedValue = Linear(hiddenSize, hiddenSize, bias: true)
    }

    /// Forward.
    /// - Parameter hiddenStates: `[B, T, D]` tokens.
    /// - Returns: `[B, T, D]` attended output.
    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        let s = hiddenStates.shape
        let B = s[0]
        let T = s[1]
        let D = s[2]

        // Project to Q, K, V — all `[B, T, D]`.
        let q = qProj(hiddenStates)
        let k = kProj(hiddenStates)
        let v = vProj(hiddenStates)

        // Reshape to multi-head + transpose to [B, num_heads, T, head_dim].
        // `transposed(0, 2, 1, 3)` swaps T and num_heads axes.
        let qH = q.reshaped([B, T, numHeads, headDim]).transposed(0, 2, 1, 3)
        let kH = k.reshaped([B, T, numHeads, headDim]).transposed(0, 2, 1, 3)
        let vH = v.reshaped([B, T, numHeads, headDim]).transposed(0, 2, 1, 3)

        // Fast scaled dot-product attention. No mask (is_causal=False;
        // SigLIP2's vision encoder is bidirectional).
        let attended = MLXFast.scaledDotProductAttention(
            queries: qH,
            keys: kH,
            values: vH,
            scale: scale,
            mask: nil
        )

        // [B, num_heads, T, head_dim] → [B, T, num_heads, head_dim] → [B, T, D]
        let merged = attended.transposed(0, 2, 1, 3).reshaped([B, T, D])
        return outProj(merged)
    }
}

// MARK: - MLP

/// Two-layer MLP with `gelu_pytorch_tanh` activation between.
///
/// Per `Siglip2MLP`:
/// ```
/// fc1 = nn.Linear(hidden_size, intermediate_size)
/// fc2 = nn.Linear(intermediate_size, hidden_size)
/// activation_fn = gelu_pytorch_tanh  (i.e. ACT2FN["gelu_pytorch_tanh"])
///
/// def forward(x):
///     return fc2(activation_fn(fc1(x)))
/// ```
///
/// MLX-Swift `geluApproximate` matches PyTorch's `nn.functional.gelu(approximate="tanh")`
/// (the `gelu_pytorch_tanh` activation) exactly. This is NOT the same function as
/// the standard `gelu` (which uses erf). Picking the wrong one is mlx-porting pitfall
/// #6 — silent ~0.5% divergence at every MLP layer that compounds across 12 layers.
final class SigLIP2MLP: Module, UnaryLayer, @unchecked Sendable {

    @ModuleInfo var fc1: Linear
    @ModuleInfo var fc2: Linear

    init(hiddenSize: Int, intermediateSize: Int) {
        self._fc1.wrappedValue = Linear(hiddenSize, intermediateSize, bias: true)
        self._fc2.wrappedValue = Linear(intermediateSize, hiddenSize, bias: true)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        fc2(geluApproximate(fc1(x)))
    }
}

// MARK: - Encoder Layer

/// One Transformer encoder layer (pre-LN ViT).
///
/// Per `Siglip2EncoderLayer`:
/// ```
/// layer_norm1 = nn.LayerNorm(embed_dim, eps=layer_norm_eps)
/// self_attn   = Siglip2Attention(config)
/// layer_norm2 = nn.LayerNorm(embed_dim, eps=layer_norm_eps)
/// mlp         = Siglip2MLP(config)
///
/// def forward(hidden_states):
///     residual = hidden_states
///     hidden_states = layer_norm1(hidden_states)
///     hidden_states = self_attn(hidden_states)
///     hidden_states = residual + hidden_states
///
///     residual = hidden_states
///     hidden_states = layer_norm2(hidden_states)
///     hidden_states = mlp(hidden_states)
///     hidden_states = residual + hidden_states
///     return hidden_states
/// ```
///
/// Pre-LN configuration (norm first, then sub-block, then residual add).
/// `layer_norm_eps = 1e-6` per Siglip2VisionConfig — NOT the more common
/// 1e-5. mlx-porting pitfall #5: get the eps right.
final class SigLIP2EncoderLayer: Module, UnaryLayer, @unchecked Sendable {

    @ModuleInfo(key: "layer_norm1") var layerNorm1: LayerNorm
    @ModuleInfo(key: "self_attn") var selfAttn: SigLIP2Attention
    @ModuleInfo(key: "layer_norm2") var layerNorm2: LayerNorm
    @ModuleInfo var mlp: SigLIP2MLP

    init(
        hiddenSize: Int,
        numAttentionHeads: Int,
        intermediateSize: Int,
        layerNormEps: Float
    ) {
        self._layerNorm1.wrappedValue = LayerNorm(dimensions: hiddenSize, eps: layerNormEps)
        self._selfAttn.wrappedValue = SigLIP2Attention(
            hiddenSize: hiddenSize,
            numAttentionHeads: numAttentionHeads
        )
        self._layerNorm2.wrappedValue = LayerNorm(dimensions: hiddenSize, eps: layerNormEps)
        self._mlp.wrappedValue = SigLIP2MLP(
            hiddenSize: hiddenSize,
            intermediateSize: intermediateSize
        )
    }

    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        // Attention sub-block (pre-LN, then residual add).
        let normed1 = layerNorm1(hiddenStates)
        let attended = selfAttn(normed1)
        let afterAttn = hiddenStates + attended

        // MLP sub-block (pre-LN, then residual add).
        let normed2 = layerNorm2(afterAttn)
        let mlpOut = mlp(normed2)
        return afterAttn + mlpOut
    }
}

// MARK: - Encoder Stack

/// `num_hidden_layers` SigLIP2EncoderLayer instances stacked.
///
/// Upstream uses `nn.ModuleList` — in MLX-Swift, an `@ModuleInfo` array
/// (the `layers` property) gives us safetensors keys `encoder.layers.{0..11}.…`
/// which match the upstream layout one-to-one.
final class SigLIP2Encoder: Module, @unchecked Sendable {

    @ModuleInfo var layers: [SigLIP2EncoderLayer]

    init(
        numHiddenLayers: Int,
        hiddenSize: Int,
        numAttentionHeads: Int,
        intermediateSize: Int,
        layerNormEps: Float
    ) {
        self._layers.wrappedValue = (0 ..< numHiddenLayers).map { _ in
            SigLIP2EncoderLayer(
                hiddenSize: hiddenSize,
                numAttentionHeads: numAttentionHeads,
                intermediateSize: intermediateSize,
                layerNormEps: layerNormEps
            )
        }
    }

    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        var h = hiddenStates
        for layer in layers {
            h = layer(h)
        }
        return h
    }
}

// MARK: - Vision Model (top-level)

/// SigLIP2 vision encoder — patch embeddings → 12-layer transformer →
/// post-layer-norm → (last_hidden_state, mean-pooler_output).
///
/// Hierarchy mirrors upstream `Siglip2VisionTransformer`:
/// ```
/// SigLIP2VisionModel
/// └─ vision_model (this class)
///    ├─ embeddings : SigLIP2VisionEmbeddings
///    ├─ encoder    : SigLIP2Encoder
///    └─ post_layernorm : LayerNorm
/// ```
///
/// Upstream additionally has a `head` (Siglip2MultiheadAttentionPoolingHead)
/// that produces the pooler output via a learnable probe. We skip this head
/// in Phase E.2 — the NR-IQA head consumes mean-pooled patch tokens. See the
/// file-level docstring for the rationale. To load weights from the
/// pretrained checkpoint, the head's keys are routed under `head.*` in the
/// safetensors and are ignored by `loadWeights(from:)`'s `.ignoreUnused`.
public final class SigLIP2VisionModel: Module, @unchecked Sendable {

    @ModuleInfo var embeddings: SigLIP2VisionEmbeddings
    @ModuleInfo var encoder: SigLIP2Encoder
    @ModuleInfo(key: "post_layernorm") var postLayerNorm: LayerNorm

    public let hiddenSize: Int
    public let numHiddenLayers: Int
    public let numAttentionHeads: Int
    public let intermediateSize: Int
    public let imageSize: Int
    public let patchSize: Int
    public let layerNormEps: Float

    /// MLXArray is not `Sendable` (it wraps a GPU graph node); we mark
    /// `Output` as `@unchecked Sendable` consistent with the existing pattern
    /// of "wrap GPU state in a class/struct with @unchecked Sendable" used by
    /// `LoadedModel` in ModelRegistry.swift and the existing NAFNet weights
    /// loaders.
    public struct Output: @unchecked Sendable {
        /// `[B, num_patches, hiddenSize]` — the full patch-token sequence
        /// after the final post_layernorm.
        public let lastHiddenState: MLXArray
        /// `[B, hiddenSize]` — mean over patch tokens. Drives the NR-IQA head.
        public let poolerOutput: MLXArray

        public init(lastHiddenState: MLXArray, poolerOutput: MLXArray) {
            self.lastHiddenState = lastHiddenState
            self.poolerOutput = poolerOutput
        }
    }

    /// Defaults match `Siglip2VisionConfig` for the
    /// `siglip2-base-patch16-224` variant. layer_norm_eps is 1e-6 per
    /// upstream — NOT the more common 1e-5. mlx-porting pitfall #5.
    public init(
        hiddenSize: Int = 768,
        numHiddenLayers: Int = 12,
        numAttentionHeads: Int = 12,
        intermediateSize: Int = 3072,
        imageSize: Int = 224,
        patchSize: Int = 16,
        layerNormEps: Float = 1e-6
    ) {
        self.hiddenSize = hiddenSize
        self.numHiddenLayers = numHiddenLayers
        self.numAttentionHeads = numAttentionHeads
        self.intermediateSize = intermediateSize
        self.imageSize = imageSize
        self.patchSize = patchSize
        self.layerNormEps = layerNormEps

        self._embeddings.wrappedValue = SigLIP2VisionEmbeddings(
            hiddenSize: hiddenSize,
            imageSize: imageSize,
            patchSize: patchSize,
            numChannels: 3
        )
        self._encoder.wrappedValue = SigLIP2Encoder(
            numHiddenLayers: numHiddenLayers,
            hiddenSize: hiddenSize,
            numAttentionHeads: numAttentionHeads,
            intermediateSize: intermediateSize,
            layerNormEps: layerNormEps
        )
        self._postLayerNorm.wrappedValue = LayerNorm(
            dimensions: hiddenSize,
            eps: layerNormEps
        )
    }

    /// Forward.
    /// - Parameter pixelValues: `[B, imageSize, imageSize, 3]` NHWC. Expected
    ///   value range matches the upstream image processor: per-channel
    ///   `mean=[0.5, 0.5, 0.5]`, `std=[0.5, 0.5, 0.5]` normalization, i.e.
    ///   `[-1, +1]` floats. Phase E.5 integration will add the preprocessing.
    /// - Returns: `Output(lastHiddenState, poolerOutput)`.
    public func callAsFunction(_ pixelValues: MLXArray) -> Output {
        let hidden0 = embeddings(pixelValues)              // [B, 196, 768]
        let encoded = encoder(hidden0)                     // [B, 196, 768]
        let lastHiddenState = postLayerNorm(encoded)       // [B, 196, 768]

        // Mean-pool over the patch dimension → [B, 768].
        // keepDims=false collapses the patch axis.
        let pooler = lastHiddenState.mean(axis: 1)         // [B, 768]

        // Materialize before return — see mlx-porting / mlx-swift skills.
        MLX.eval(lastHiddenState, pooler)

        return Output(lastHiddenState: lastHiddenState, poolerOutput: pooler)
    }
}

// MARK: - Weight loading

/// Errors raised by SigLIP2VisionModel's weight-loading helper.
public enum SigLIP2WeightError: Error, Sendable, CustomStringConvertible {
    case weightsNotFound(String)
    case loadFailed(String)

    public var description: String {
        switch self {
        case .weightsNotFound(let path):
            return "SigLIP2 weights file not found: \(path)"
        case .loadFailed(let detail):
            return "SigLIP2 weight load failed: \(detail)"
        }
    }
}

public extension SigLIP2VisionModel {

    /// Load weights from a safetensors file produced by
    /// `SigLIP2BackboneLoader.ensureWeights()` (i.e. the upstream
    /// `mlx-community/siglip2-base-patch16-224-8bit/model.safetensors`).
    ///
    /// Conversions handled:
    ///   - PyTorch Conv2d patch_embedding weight is `[out=768, in=3, kH=16, kW=16]`
    ///     in NCHW; MLX expects `[out, kH, kW, in]`. The converter detects shape-4
    ///     conv weights and transposes accordingly.
    ///   - Key prefix `vision_model.` (used by the full SigLIP2 model dump
    ///     when both vision + text encoders are saved together) is stripped
    ///     so the weight tree maps onto the bare `SigLIP2VisionModel`
    ///     hierarchy.
    ///   - Pooling-head keys (`head.*`, `vision_model.head.*`) are dropped
    ///     because we skip the MAP head — Phase E.2 brief uses mean-pool.
    ///   - 8-bit quantization scales/biases (`*.scales`, `*.biases`) are
    ///     dropped for the same reason as the head: until Phase E.5 wires
    ///     quantization-aware loading, we just take the unquantized weight
    ///     tensor. The mlx-community 8bit checkpoint stores the dequantized
    ///     weights as fp16 alongside the quantization metadata; we use the
    ///     fp16 tensors directly. (NOTE: this means E.2's `loadIntoMLX` is
    ///     for architecture verification only — Phase E.5 should swap in
    ///     proper QuantizedLinear modules to actually exploit the 8-bit
    ///     compression on disk.)
    ///
    /// Uses `update(parameters:verify: .none)` rather than `.noUnusedKeys`
    /// because the pretrained checkpoint carries the MAP head + (optional)
    /// text encoder + quant metadata that this port intentionally doesn't
    /// load. The pre-filter above drops those keys from the dict; `.none`
    /// then accepts that the module tree doesn't see them. Phase E.5 may
    /// switch to `.noUnusedKeys` once MAP + quant are wired.
    func loadWeights(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SigLIP2WeightError.weightsNotFound(url.path)
        }

        let rawArrays: [String: MLXArray]
        do {
            rawArrays = try MLX.loadArrays(url: url)
        } catch {
            throw SigLIP2WeightError.loadFailed(String(describing: error))
        }

        // Filter + remap keys.
        var mapped: [String: MLXArray] = [:]
        for (key, value) in rawArrays {
            // Drop text encoder + pooling head + quantization metadata.
            if key.contains(".scales") || key.contains(".biases")
                || key.hasPrefix("text_model.") || key.contains(".head.")
                || key.hasPrefix("vision_model.head.") || key.hasPrefix("head.")
                || key == "logit_scale" || key == "logit_bias" {
                continue
            }

            // Strip `vision_model.` prefix if present.
            var k = key
            if k.hasPrefix("vision_model.") {
                k.removeFirst("vision_model.".count)
            }

            // Conv2d patch_embedding weight: NCHW [out, in, kH, kW] →
            // NHWC [out, kH, kW, in]. The Linear layers in the encoder
            // already have the standard [out, in] layout and need no
            // transpose. Detect by key suffix.
            if k == "embeddings.patch_embedding.weight" && value.shape.count == 4 {
                mapped[k] = value.transposed(0, 2, 3, 1)
            } else {
                mapped[k] = value
            }
        }

        let loaded = ModuleParameters.unflattened(mapped)
        do {
            try update(parameters: loaded, verify: .none)
        } catch {
            throw SigLIP2WeightError.loadFailed(String(describing: error))
        }

        MLX.eval(parameters())
    }
}
