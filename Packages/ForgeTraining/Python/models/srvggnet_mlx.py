"""
SRVGGNetCompact reference implementation in MLX-Python.

This is the MLX-Python twin of ``Packages/ForgeUpscaler/Sources/ForgeUpscaler/
Playback/SRVGGNetCompact.swift``. It exists for the same reason as
``efrlfn_mlx.py``: the Swift port runs only inside Xcode (MLX needs the Metal
library that Xcode bundles), so an MLX-Python twin gives us a CPU-runnable
oracle for the Phase C.4 weight converter + PyTorch parity tests.

Architecture
------------

A verbatim port of upstream
``xinntao/Real-ESRGAN/realesrgan/archs/srvgg_arch.py`` (BSD-3-Clause, © 2021
Xintao Wang). Three variants by ``(num_feat, num_conv, act_type)``:

    realesr-general-x4v3       (64, 32, prelu)    1,213,296 params
    realesr-general-wdn-x4v3   (64, 32, prelu)    1,213,296 params  (same arch)
    realesr-animevideov3       (64, 16, prelu)      621,424 params

Quirks (per upstream `srvgg_arch.py`)
-------------------------------------

1. Residual upsample is **nearest**, not bilinear:
   ``F.interpolate(x, scale_factor=self.upscale, mode='nearest')``.
2. PReLU uses ``num_parameters=num_feat`` (one alpha per channel), not the
   shared-scalar variant.
3. State-dict layout is a flat ``nn.ModuleList`` indexed by integer:
   ``body.0 .. body.{2*num_conv+2}``. PReLU activations only contribute
   ``.weight`` (no bias).
4. The architecture supports ``act_type='relu' | 'prelu' | 'leakyrelu'``;
   all three vendored v3 variants ship with ``prelu``.

Layout
------

- NHWC throughout (MLX default).
- Conv2d weight shape: ``(O, kH, kW, I)``.
- PReLU weight shape: ``(num_feat,)`` — same as PyTorch.

Plan ref
--------
Docs/Forge-CodingPlan-v1.0.md §C — playback-tier baseline (Task #28)
ADR: Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md §"Ship criterion"
"""

from __future__ import annotations

import mlx.core as mx
import mlx.nn as nn


# ----------------------------------------------------------------------------
# Conv helper
# ----------------------------------------------------------------------------

def _same_conv(in_ch: int, out_ch: int, k: int, *, bias: bool = True) -> nn.Conv2d:
    """3×3 / 1×1 'same' Conv2d with the upstream padding convention."""
    return nn.Conv2d(
        in_channels=in_ch,
        out_channels=out_ch,
        kernel_size=k,
        padding=(k - 1) // 2,
        bias=bias,
    )


# ----------------------------------------------------------------------------
# PixelShuffle (NHWC)
# ----------------------------------------------------------------------------

def _pixel_shuffle_nhwc(x: mx.array, upscale_factor: int) -> mx.array:
    """Reshape-and-transpose pixel shuffle for NHWC tensors.

    Same logic as ``efrlfn_mlx._pixel_shuffle_nhwc`` — uses the verified
    ``(C, r, r)`` channel split ordering that matches PyTorch's
    ``nn.PixelShuffle``. The ``(r, r, C)`` variant produces correct shapes
    but wrong content (max_abs ≈ 2.27 in parity tests). Duplicated rather
    than imported because the two files are upstream-reference twins and
    keeping each self-contained makes diffing the upstream model easier.
    """
    r = upscale_factor
    n, h, w, c_in = x.shape
    if c_in % (r * r) != 0:
        raise ValueError(
            f"pixel_shuffle: input channels {c_in} not divisible by r*r={r*r}"
        )
    c = c_in // (r * r)
    # [N, H, W, C, r_i, r_j]
    reshaped = x.reshape((n, h, w, c, r, r))
    # [N, H, r_i, W, r_j, C]
    transposed = mx.transpose(reshaped, (0, 1, 4, 2, 5, 3))
    # [N, H*r, W*r, C]
    return transposed.reshape((n, h * r, w * r, c))


# ----------------------------------------------------------------------------
# Nearest-neighbour upsample (NHWC)
# ----------------------------------------------------------------------------

def _upsample_nearest_nhwc(x: mx.array, factor: int) -> mx.array:
    """Element-wise replicate along the H and W axes.

    Matches ``F.interpolate(x, scale_factor=factor, mode='nearest')`` for
    integer ``factor`` and 4-D NHWC tensors. Element-wise repeat (each
    input is duplicated ``factor`` times in place), NOT block tile
    (``[A,A,B,B]`` vs ``[A,B,A,B]``). The ``mx.repeat`` op handles this
    along a chosen axis.
    """
    if factor == 1:
        return x
    # H axis = 1, W axis = 2 in NHWC.
    y = mx.repeat(x, repeats=factor, axis=1)
    y = mx.repeat(y, repeats=factor, axis=2)
    return y


# ----------------------------------------------------------------------------
# Activation
# ----------------------------------------------------------------------------

class _Activation(nn.Module):
    """Wraps PReLU / LeakyReLU under a single key-stable interface.

    For PReLU, holds the per-channel learnable ``alpha`` as ``self.weight``
    (a tracked parameter), matching PyTorch's ``nn.PReLU.weight``. The
    converter remaps upstream ``body.{2k+1}.weight`` directly onto this
    attribute via the index translation in
    ``Scripts.convert_srvggnet_to_mlx._remap_key``.

    For LeakyReLU there are no parameters; the slot is parameter-free and
    the forward call is a pure function.
    """

    def __init__(self, kind: str, channels: int, leaky_slope: float = 0.1) -> None:
        super().__init__()
        if kind not in ("prelu", "leakyrelu"):
            raise ValueError(f"unsupported activation kind: {kind!r}")
        self._kind = kind
        self._leaky_slope = leaky_slope

        if kind == "prelu":
            # PyTorch's nn.PReLU default init = 0.25. The upstream checkpoint
            # overwrites this on load.
            self.weight = mx.full((channels,), 0.25, dtype=mx.float32)

    def __call__(self, x: mx.array) -> mx.array:
        if self._kind == "prelu":
            # PReLU: where(x > 0, x, alpha * x). Alpha broadcasts over the
            # spatial axes — NHWC means alpha shape (C,) aligns with the
            # trailing axis automatically.
            return mx.where(x > 0, x, self.weight * x)
        # LeakyReLU.
        return mx.where(x > 0, x, x * self._leaky_slope)


# ----------------------------------------------------------------------------
# SRVGGNetCompact
# ----------------------------------------------------------------------------

class SRVGGNetCompact(nn.Module):
    """Compact VGG-style SR network used by Real-ESRGAN.

    State-dict key scheme (matches upstream + the Swift port's
    ``@ModuleInfo`` flatten via the converter's index remap):

        first_conv.weight, first_conv.bias       # body.0 in upstream
        first_act.weight                          # body.1 (PReLU alpha)
        body_pairs.0.conv.{weight,bias}           # body.2
        body_pairs.0.act.weight                   # body.3
        ...
        body_pairs.{num_conv-1}.conv.{weight,bias}  # body.{2*num_conv}
        body_pairs.{num_conv-1}.act.weight          # body.{2*num_conv+1}
        last_conv.{weight,bias}                   # body.{2*num_conv+2}

    The converter rewrites upstream ``body.{N}`` indices to this scheme;
    the Swift port uses identical names so the safetensors loads cleanly
    on both backends.
    """

    def __init__(
        self,
        num_in_ch: int = 3,
        num_out_ch: int = 3,
        num_feat: int = 64,
        num_conv: int = 32,
        upscale: int = 4,
        act_type: str = "prelu",
    ) -> None:
        super().__init__()
        if num_in_ch < 1:
            raise ValueError(f"num_in_ch must be >= 1, got {num_in_ch}")
        if num_out_ch < 1:
            raise ValueError(f"num_out_ch must be >= 1, got {num_out_ch}")
        if num_feat < 1:
            raise ValueError(f"num_feat must be >= 1, got {num_feat}")
        if num_conv < 0:
            raise ValueError(f"num_conv must be >= 0, got {num_conv}")
        if upscale < 1:
            raise ValueError(f"upscale must be >= 1, got {upscale}")
        if act_type not in ("prelu", "leakyrelu"):
            # The upstream code also supports 'relu' but none of the v3
            # checkpoints use it; refuse rather than silently allow.
            raise ValueError(f"unsupported act_type: {act_type!r}")

        self.num_in_ch = num_in_ch
        self.num_out_ch = num_out_ch
        self.num_feat = num_feat
        self.num_conv = num_conv
        self.upscale = upscale
        self.act_type = act_type

        # First conv + first activation.
        self.first_conv = _same_conv(num_in_ch, num_feat, 3)
        self.first_act = _Activation(act_type, num_feat)

        # Body: numConv (conv + activation) pairs.
        # MLX-Python supports list attributes as parameter sub-trees, but we
        # use a regular list and explicit attribute access so the parameter
        # flatten produces "body_pairs.{i}.conv.weight" — matching the Swift
        # port's @ModuleInfo flatten exactly.
        body_pairs: list[_BodyPair] = []
        for _ in range(num_conv):
            body_pairs.append(_BodyPair(num_feat, act_type))
        self.body_pairs = body_pairs

        # Last conv: num_feat → num_out * upscale².
        self.last_conv = _same_conv(num_feat, num_out_ch * upscale * upscale, 3)

    def __call__(self, x: mx.array) -> mx.array:
        """Forward.

        Args:
            x: ``[N, H, W, num_in_ch]`` NHWC tensor in ``[0, 1]``.

        Returns:
            ``[N, H * upscale, W * upscale, num_out_ch]``.
        """
        out = self.first_act(self.first_conv(x))
        for pair in self.body_pairs:
            out = pair(out)
        out = self.last_conv(out)

        if self.upscale != 1:
            out = _pixel_shuffle_nhwc(out, self.upscale)

        base = _upsample_nearest_nhwc(x, self.upscale)
        return out + base


class _BodyPair(nn.Module):
    """One body conv + activation. Mirrors ``SRVGGNetCompact.BodyPair`` in Swift."""

    def __init__(self, channels: int, act_type: str) -> None:
        super().__init__()
        self.conv = _same_conv(channels, channels, 3)
        self.act = _Activation(act_type, channels)

    def __call__(self, x: mx.array) -> mx.array:
        return self.act(self.conv(x))


# ----------------------------------------------------------------------------
# Variant factories
# ----------------------------------------------------------------------------

def general(upscale: int = 4) -> SRVGGNetCompact:
    """`realesr-general-x4v3` config — general photos / video."""
    return SRVGGNetCompact(
        num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32,
        upscale=upscale, act_type="prelu",
    )


def general_wdn(upscale: int = 4) -> SRVGGNetCompact:
    """`realesr-general-wdn-x4v3` config — same arch as general, WDN training."""
    return SRVGGNetCompact(
        num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32,
        upscale=upscale, act_type="prelu",
    )


def anime(upscale: int = 4) -> SRVGGNetCompact:
    """`realesr-animevideov3` config — half-depth body for real-time anime."""
    return SRVGGNetCompact(
        num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=16,
        upscale=upscale, act_type="prelu",
    )
