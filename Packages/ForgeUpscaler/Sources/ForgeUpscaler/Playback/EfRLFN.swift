//
//  EfRLFN.swift
//  ForgeUpscaler / Playback
//
//  Role: MLX-Swift port of EfRLFN (Efficient Residual Local Feature Network),
//        a lightweight real-time super-resolution architecture tuned for
//        streaming UGC. Candidate replacement for SRVGGNetCompact in the
//        playback tier. ~0.5M params (~1 MB FP16) at the upstream default
//        config (feature_channels=52, 6 ERLFB blocks, scale=4).
//
//  Plan ref: Forge-CodingPlan-v1.0.md §C.2 / Task #18 (Phase C.2)
//  ADR: Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md
//  Upstream: https://github.com/EvgeneyBogatyrev/EfRLFN  (MIT)
//  Paper: arXiv:2602.11339 (ICLR 2026, Bogatyrev et al. / Lomonosov MSU)
//
//  Architecture summary (per upstream `code/model.py` + `code/blocks.py`):
//    - conv_1 (3×3, 3 → feature_channels)
//    - 6 × ERLFB (the residual local feature block)
//        - 3× (3×3 conv c→c → tanh), then + x residual, then 1×1 conv c→c,
//          then ECABlock
//    - conv_2 (3×3, feature_channels → feature_channels), input is
//      (out_b6 + out_feature) — a global residual from the conv_1 output
//    - pixelshuffle_block: conv (3×3, fc → out_c * scale^2) + PixelShuffle(scale)
//
//  ECABlock (Efficient Channel Attention, Wang et al. CVPR 2020) per the
//  upstream impl uses a *fixed* `k_size=3` 1-D conv along the channel axis,
//  not the standard log2(C)/γ formula. We preserve the upstream choice for
//  weight-load compatibility — see ECABlock docstring.
//
//  Conventions:
//    - NHWC tensor layout (MLX-Swift default; matches CLAUDE.md)
//    - `@unchecked Sendable` for classes that hold MLX state (existing convention)
//    - Weight loading uses the standard MLX.loadArrays → ModuleParameters.unflattened
//      → Module.update(verify: .noUnusedKeys) pipeline (see NAFNet.swift, LiteFlowNet.swift)
//
//  Numerical correctness against the PyTorch reference is verified in Phase C.3
//  (Task #20) once the convert_efrlfn_to_mlx.py weight converter and trained
//  weights land. The tests in this phase verify architecture only (shapes,
//  parameter count, ECA standalone forward).
//
//  License note (architecture port specifically):
//    The upstream EfRLFN code (model.py, blocks.py) is MIT, ©2026 Evgeney
//    Bogatyrev et al. The published checkpoint at /weights is MIT as well.
//    Any fine-tune on a non-upstream corpus is blocked on the StreamSR
//    training-data legal review captured in Task #19 — that gate applies to
//    *retraining*, not this architecture-only port. See ADR-0006 §"StreamSR
//    data provenance" and Packages/ForgeUpscaler/LICENSES.md §1A.
//

import Foundation
import MLX
import MLXNN

// MARK: - Conv layer helper

/// Build a 2-D conv with "same" zero padding for a given odd kernel size.
///
/// Upstream `code/blocks.py:conv_layer` uses `padding = (k-1) // 2` on each axis;
/// this matches PyTorch's `padding=(p, p)` style. MLXNN's `Conv2d` takes a single
/// `padding: Int` that applies to both axes, which yields the same behaviour for
/// the square 3×3 / 1×1 kernels EfRLFN uses.
@inline(__always)
private func sameConv(
    _ inCh: Int,
    _ outCh: Int,
    kernel k: Int,
    bias: Bool = true
) -> Conv2d {
    Conv2d(
        inputChannels: inCh,
        outputChannels: outCh,
        kernelSize: .init(k),
        stride: 1,
        padding: .init((k - 1) / 2),
        bias: bias
    )
}

// MARK: - ECA (Efficient Channel Attention)

/// Efficient Channel Attention block.
///
/// Per the upstream `code/blocks.py:ECABlock`, this implementation uses a fixed
/// `k_size=3` 1-D convolution along the channel axis — *not* the standard
/// `k = |log2(C)+b|/γ` formula from the ECA paper (Wang et al., CVPR 2020).
/// We preserve the upstream choice for weight-load compatibility with the
/// published EfRLFN checkpoint; any future config knob to enable the adaptive
/// formula should live alongside a separately-released set of weights.
///
/// PyTorch reference forward:
/// ```python
/// y = self.avg_pool(x).squeeze(-1).permute(0, 2, 1)   # NCHW: [N,C,1,1] → [N,1,C]
/// y = self.conv(y).permute(0, 2, 1).unsqueeze(-1)     # [N,1,C] → [N,C,1,1]
/// y = self.sigmoid(y)
/// return x * y
/// ```
/// In NHWC the channels are already last, so the permutes collapse: we mean
/// over the spatial axes to get `[N, 1, C]` (treating C as the 1-D sequence
/// length L for Conv1d's NLC layout), run the 1-D conv, sigmoid, and reshape
/// to `[N, 1, 1, C]` for broadcast.
final class ECABlock: Module, UnaryLayer, @unchecked Sendable {

    @ModuleInfo var conv: Conv1d

    init(kSize: Int = 3) {
        precondition(kSize % 2 == 1, "ECABlock kSize must be odd; got \(kSize)")
        // Conv1d expects NLC layout. With C treated as the L (sequence) axis
        // and a single "channel" of 1, we get the upstream channel-wise
        // attention: one shared 1-D kernel slides over the channel sequence.
        // bias=false matches upstream.
        self._conv.wrappedValue = Conv1d(
            inputChannels: 1,
            outputChannels: 1,
            kernelSize: kSize,
            stride: 1,
            padding: (kSize - 1) / 2,
            bias: false
        )
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: [N, H, W, C] (NHWC).
        // Global average pool over (H, W) → [N, 1, 1, C].
        let pooled = x.mean(axes: [1, 2], keepDims: true)

        // Reshape to NLC for Conv1d: L=C, channels=1.
        let s = pooled.shape           // [N, 1, 1, C]
        let N = s[0]
        let C = s[3]
        let lc = pooled.reshaped([N, C, 1])   // [N, L=C, channels=1]

        // 1-D conv along the channel axis.
        let attended = conv(lc)              // [N, C, 1]

        // Sigmoid → broadcast multiply with input.
        let weights = MLX.sigmoid(attended.reshaped([N, 1, 1, C]))  // [N, 1, 1, C]
        return x * weights
    }
}

// MARK: - ERLFB (Efficient Residual Local Feature Block)

/// The core repeating unit of EfRLFN.
///
/// Per upstream `code/blocks.py:ERLFB`:
/// ```
/// out = tanh(c1_r(x))               # 3×3 conv, c → c
/// out = tanh(c2_r(out))              # 3×3 conv, c → c
/// out = tanh(c3_r(out))              # 3×3 conv, c → c
/// out = out + x                      # local residual
/// out = eca(c5(out))                 # 1×1 conv, c → c, then ECA
/// ```
///
/// Notable points:
///   - **tanh activation** — bounded `[-1, 1]` output. Uncommon for SR but the
///     paper picks it for the bounded-output property. No learnable params in
///     the activation itself, so no key in the safetensors dump.
///   - The `esa_channels=16` keyword in upstream `__init__` is **unused** in
///     the forward path (legacy from the RLFN ancestor's ESA block, which was
///     replaced by ECA). We do not surface it on the Swift side.
///   - `mid_channels` / `out_channels` default to `in_channels` — the upstream
///     model.py only ever instantiates ERLFB with a single channel arg, so we
///     hardcode the c → c case rather than expose three knobs that are never
///     varied.
final class ERLFB: Module, UnaryLayer, @unchecked Sendable {

    @ModuleInfo var c1_r: Conv2d
    @ModuleInfo var c2_r: Conv2d
    @ModuleInfo var c3_r: Conv2d
    @ModuleInfo var c5: Conv2d
    @ModuleInfo var eca: ECABlock

    init(channels c: Int) {
        self._c1_r.wrappedValue = sameConv(c, c, kernel: 3)
        self._c2_r.wrappedValue = sameConv(c, c, kernel: 3)
        self._c3_r.wrappedValue = sameConv(c, c, kernel: 3)
        self._c5.wrappedValue   = sameConv(c, c, kernel: 1)
        self._eca.wrappedValue  = ECABlock()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = MLX.tanh(c1_r(x))
        out = MLX.tanh(c2_r(out))
        out = MLX.tanh(c3_r(out))
        out = out + x
        return eca(c5(out))
    }
}

// MARK: - PixelShuffle (NHWC)

/// Upsample by `r` via channel-to-space reshuffling.
/// Input  : `[N, H, W, C * r * r]`
/// Output : `[N, H * r, W * r, C]`
///
/// PyTorch's `nn.PixelShuffle` operates on NCHW. The NHWC equivalent is a
/// reshape + transpose + reshape with no learnable params. Local to this file
/// because `NAFNet.swift`'s `pixelShuffleNHWC` lives in ForgeOptimizer and is
/// internal — duplicating the ~10-line helper here is simpler than promoting
/// it to the package surface.
private func pixelShuffleNHWC(_ x: MLXArray, upscaleFactor r: Int) -> MLXArray {
    let s = x.shape
    let N = s[0]
    let H = s[1]
    let W = s[2]
    let Cin = s[3]
    precondition(Cin % (r * r) == 0,
                 "pixelShuffleNHWC: input channels (\(Cin)) must be divisible by r*r (\(r * r))")
    let C = Cin / (r * r)

    // Channel-split uses (C, r, r) ordering to match PyTorch's nn.PixelShuffle,
    // which reads input channel index `c*r*r + i*r + j` for output channel `c`
    // at sub-pixel (i, j). Phase C.3 parity testing caught the previous
    // (r, r, C) variant — it produced max_abs ≈ 2.27 in the upsampler vs
    // ≈ 1e-6 with this layout. NAFNet.swift carries the same fix.
    //
    // [N, H, W, C, r_i, r_j]
    let reshaped = x.reshaped([N, H, W, C, r, r])
    // Permute so r_i sits next to H, r_j next to W, C trails:
    // [N, H, r_i, W, r_j, C]
    let transposed = reshaped.transposed(0, 1, 4, 2, 5, 3)
    // [N, H*r, W*r, C]
    return transposed.reshaped([N, H * r, W * r, C])
}

// MARK: - Upsampler

/// `pixelshuffle_block` from upstream `code/blocks.py`.
///
/// Sequential of (3×3 conv `feature_channels → out_channels * scale^2`) +
/// `PixelShuffle(scale)`. The conv carries learnable weights; the shuffle is
/// pure shape op.
final class PixelShuffleBlock: Module, UnaryLayer, @unchecked Sendable {

    @ModuleInfo var conv: Conv2d
    let scale: Int

    init(inChannels: Int, outChannels: Int, scale: Int) {
        precondition(scale >= 1, "EfRLFN scale must be ≥ 1; got \(scale)")
        self._conv.wrappedValue = sameConv(
            inChannels,
            outChannels * scale * scale,
            kernel: 3
        )
        self.scale = scale
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let y = conv(x)
        if scale == 1 {
            return y
        }
        return pixelShuffleNHWC(y, upscaleFactor: scale)
    }
}

// MARK: - EfRLFN

/// EfRLFN — Efficient Residual Local Feature Network for real-time SR.
///
/// Per upstream `code/model.py`. The defaults below match the upstream
/// implementation exactly (in/out channels = 3, feature_channels = 52,
/// six ERLFB blocks, scale = 4); these are the values used by the
/// published MIT-licensed checkpoint that Phase C.3 will convert.
///
/// Forward pass:
/// 1. `conv_1` lifts 3 channels → `featureChannels`.
/// 2. Six ERLFB blocks in sequence at `featureChannels`.
/// 3. `conv_2` runs over `out_b6 + conv_1_output` — a global residual back to
///    the conv_1 activation.
/// 4. `upsampler` (3×3 conv to `out_c * scale^2`) + `PixelShuffle(scale)`.
///
/// No internal downsampling, so no padding-to-multiple constraint on H/W.
public final class EfRLFN: Module, @unchecked Sendable {

    @ModuleInfo var conv_1: Conv2d
    @ModuleInfo var conv_2: Conv2d

    @ModuleInfo var block_1: ERLFB
    @ModuleInfo var block_2: ERLFB
    @ModuleInfo var block_3: ERLFB
    @ModuleInfo var block_4: ERLFB
    @ModuleInfo var block_5: ERLFB
    @ModuleInfo var block_6: ERLFB

    @ModuleInfo var upsampler: PixelShuffleBlock

    public let imgChannels: Int
    public let featureChannels: Int
    public let numBlocks: Int
    public let scale: Int

    /// - Parameters:
    ///   - imgChannels: input/output channel count. Upstream default = 3 (RGB).
    ///   - featureChannels: internal feature width. Upstream default = 52.
    ///   - numBlocks: number of stacked ERLFB blocks. Upstream default = 6.
    ///     Currently fixed to 6 to match the published checkpoint's
    ///     parameter-key layout (`block_1` ... `block_6`). Passing any other
    ///     value triggers a precondition trap — wire a flexible list if a
    ///     future variant ships a different stack depth.
    ///   - scale: super-resolution factor (typically 2 or 4). Upstream
    ///     default = 4.
    public init(
        imgChannels: Int = 3,
        featureChannels: Int = 52,
        numBlocks: Int = 6,
        scale: Int = 4
    ) {
        precondition(numBlocks == 6,
                     "EfRLFN currently fixes numBlocks=6 to match the upstream checkpoint's block_1..block_6 keys; got \(numBlocks)")
        precondition(scale >= 1, "EfRLFN scale must be ≥ 1; got \(scale)")

        self.imgChannels = imgChannels
        self.featureChannels = featureChannels
        self.numBlocks = numBlocks
        self.scale = scale

        self._conv_1.wrappedValue = sameConv(imgChannels, featureChannels, kernel: 3)
        self._conv_2.wrappedValue = sameConv(featureChannels, featureChannels, kernel: 3)

        self._block_1.wrappedValue = ERLFB(channels: featureChannels)
        self._block_2.wrappedValue = ERLFB(channels: featureChannels)
        self._block_3.wrappedValue = ERLFB(channels: featureChannels)
        self._block_4.wrappedValue = ERLFB(channels: featureChannels)
        self._block_5.wrappedValue = ERLFB(channels: featureChannels)
        self._block_6.wrappedValue = ERLFB(channels: featureChannels)

        self._upsampler.wrappedValue = PixelShuffleBlock(
            inChannels: featureChannels,
            outChannels: imgChannels,
            scale: scale
        )
    }

    /// Forward pass.
    /// - Parameter x: `[N, H, W, imgChannels]` NHWC image tensor in the value
    ///   range matching the published checkpoint's training preprocessing
    ///   (typically `[0, 1]` floats — Phase C.3's weight converter pins the
    ///   exact range).
    /// - Returns: `[N, H * scale, W * scale, imgChannels]` super-resolved image.
    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let outFeature = conv_1(x)

        var out = block_1(outFeature)
        out = block_2(out)
        out = block_3(out)
        out = block_4(out)
        out = block_5(out)
        out = block_6(out)

        let outLowResolution = conv_2(out + outFeature)
        return upsampler(outLowResolution)
    }
}

// MARK: - Weight loading

/// Errors raised by EfRLFN's weight-loading helpers.
public enum EfRLFNError: Error, Sendable, CustomStringConvertible {
    case weightsNotFound(String)
    case loadFailed(String)

    public var description: String {
        switch self {
        case .weightsNotFound(let path):
            return "EfRLFN weights file not found: \(path)"
        case .loadFailed(let detail):
            return "EfRLFN weight load failed: \(detail)"
        }
    }
}

public extension EfRLFN {
    /// Load weights from a safetensors file produced by Phase C.3's
    /// `convert_efrlfn_to_mlx.py`.
    ///
    /// The converter is expected to:
    /// - Transpose conv weights from PyTorch `[out, in, kH, kW]` to MLX
    ///   `[out, kH, kW, in]`.
    /// - For the ECA Conv1d, transpose `[out, in, k]` to `[out, k, in]`
    ///   (MLX-Swift Conv1d uses NLC kernel layout).
    /// - Map upstream parameter keys onto this Swift hierarchy. Upstream
    ///   names already match: `conv_1`, `conv_2`, `block_1..block_6`,
    ///   `block_N.c1_r/c2_r/c3_r/c5`, `block_N.eca.conv`, and the
    ///   sequential `upsampler.0` → here it's `upsampler.conv` because we
    ///   wrap the (conv, PixelShuffle) sequential in a named module rather
    ///   than `nn.Sequential` — the converter rewrites the prefix.
    ///
    /// Uses the standard MLX-Swift pattern from LiteFlowNet / NAFNet:
    /// `MLX.loadArrays` → `ModuleParameters.unflattened` → `update(verify:)`.
    /// `.noUnusedKeys` catches converter drift (extra keys in the file the
    /// model doesn't consume).
    func loadWeights(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EfRLFNError.weightsNotFound(url.path)
        }

        let arrays: [String: MLXArray]
        do {
            arrays = try MLX.loadArrays(url: url)
        } catch {
            throw EfRLFNError.loadFailed(String(describing: error))
        }

        let loaded = ModuleParameters.unflattened(arrays)
        do {
            try update(parameters: loaded, verify: .noUnusedKeys)
        } catch {
            throw EfRLFNError.loadFailed(String(describing: error))
        }

        MLX.eval(parameters())
    }
}
