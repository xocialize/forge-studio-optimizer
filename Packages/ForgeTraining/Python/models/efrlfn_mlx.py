"""
EfRLFN reference implementation in MLX-Python.

This is the MLX-Python twin of ``Packages/ForgeUpscaler/Sources/ForgeUpscaler/
Playback/EfRLFN.swift``. The architecture is a verbatim port of upstream
``code/model.py`` + ``code/blocks.py`` from https://github.com/EvgeneyBogatyrev/
EfRLFN (MIT, ICLR 2026), kept in sync with the Swift implementation so the
Phase C.3 weight converter has something to numerically validate against.

Why a Python twin
-----------------

- The Swift port runs only inside Xcode (MLX needs the Metal library that
  Xcode bundles at runtime). For an offline parity test from the command line
  we need an MLX execution path that works on CPU/Metal under the venv.
- Keeping the Python reference in this package — not in ForgeUpscaler — keeps
  the rule "no Python in Forge.app" intact.

Architecture quirks (per ADR-0006 §"Verified at port")
-------------------------------------------------------

1. ECA uses fixed ``k_size=3`` (not the log2(C)/γ formula).
2. ``esa_channels`` / ``mid_channels`` / ``out_channels`` kwargs from upstream
   ``ERLFB`` are unused in forward — dropped.
3. ``conv_2`` input is ``out_b6 + conv_1_output`` (global residual).
4. No internal downsampling.
5. ``numBlocks=6`` precondition-locked.
6. Param count at upstream defaults: 503,894 (scale=4), 487,010 (scale=2).

Layout
------

- NHWC throughout (MLX default; matches mlx-swift).
- Conv2d weight shape: ``(O, kH, kW, I)``.
- Conv1d weight shape: ``(O, k, I)`` with NLC input layout.

Plan ref
--------
Docs/Forge-CodingPlan-v1.0.md §C.3 (Task #20).
"""

from __future__ import annotations

import mlx.core as mx
import mlx.nn as nn


# ----------------------------------------------------------------------------
# Conv helper
# ----------------------------------------------------------------------------

def _same_conv(in_ch: int, out_ch: int, k: int, *, bias: bool = True) -> nn.Conv2d:
    """3×3 or 1×1 'same' Conv2d with the upstream padding convention."""
    return nn.Conv2d(
        in_channels=in_ch,
        out_channels=out_ch,
        kernel_size=k,
        padding=(k - 1) // 2,
        bias=bias,
    )


# ----------------------------------------------------------------------------
# ECABlock — channel attention
# ----------------------------------------------------------------------------

class ECABlock(nn.Module):
    """Efficient Channel Attention with the upstream fixed ``k_size=3``.

    Forward in NHWC:
        1. Mean over ``(H, W)`` to ``[N, 1, 1, C]``.
        2. Reshape to NLC ``[N, C, 1]`` for ``Conv1d``.
        3. ``Conv1d(1→1, k=3)`` along the channel axis.
        4. Sigmoid + broadcast multiply.

    Matches ``EfRLFN.swift::ECABlock`` exactly.
    """

    def __init__(self, k_size: int = 3) -> None:
        super().__init__()
        if k_size % 2 != 1:
            raise ValueError(f"ECABlock k_size must be odd; got {k_size}")
        self.conv = nn.Conv1d(
            in_channels=1,
            out_channels=1,
            kernel_size=k_size,
            padding=(k_size - 1) // 2,
            bias=False,
        )

    def __call__(self, x: mx.array) -> mx.array:
        # x: [N, H, W, C]
        pooled = mx.mean(x, axis=(1, 2), keepdims=True)  # [N, 1, 1, C]
        n, _, _, c = pooled.shape
        lc = pooled.reshape((n, c, 1))            # [N, L=C, 1]
        attended = self.conv(lc)                  # [N, C, 1]
        weights = mx.sigmoid(attended.reshape((n, 1, 1, c)))
        return x * weights


# ----------------------------------------------------------------------------
# ERLFB — Efficient Residual Local Feature Block
# ----------------------------------------------------------------------------

class ERLFB(nn.Module):
    """Three 3×3 tanh convs + local residual + 1×1 conv + ECA."""

    def __init__(self, channels: int) -> None:
        super().__init__()
        self.c1_r = _same_conv(channels, channels, 3)
        self.c2_r = _same_conv(channels, channels, 3)
        self.c3_r = _same_conv(channels, channels, 3)
        self.c5 = _same_conv(channels, channels, 1)
        self.eca = ECABlock()

    def __call__(self, x: mx.array) -> mx.array:
        out = mx.tanh(self.c1_r(x))
        out = mx.tanh(self.c2_r(out))
        out = mx.tanh(self.c3_r(out))
        out = out + x
        return self.eca(self.c5(out))


# ----------------------------------------------------------------------------
# PixelShuffle (NHWC)
# ----------------------------------------------------------------------------

def _pixel_shuffle_nhwc(x: mx.array, upscale_factor: int) -> mx.array:
    """Reshape-and-transpose pixel shuffle for NHWC tensors.

    Numerically equivalent to ``torch.nn.PixelShuffle`` once you account for
    NHWC vs NCHW:

    PyTorch ``[N, C*r², H, W] → [N, C, H*r, W*r]``: the input is viewed as
    ``[N, C, r, r, H, W]`` (channels grouped as ``(C, r, r)`` — outer C,
    inner two are the spatial sub-positions).

    For NHWC the input is ``[N, H, W, C*r²]`` so the channel reshape is
    ``(C, r, r)`` followed by a permute that places ``r`` next to the
    corresponding spatial axis. See ``EfRLFN.swift::pixelShuffleNHWC``
    note (the C.2 port used ``(r, r, C)`` ordering — this implementation
    uses the verified ``(C, r, r)`` ordering that matches upstream PyTorch).
    """
    r = upscale_factor
    n, h, w, c_in = x.shape
    if c_in % (r * r) != 0:
        raise ValueError(
            f"pixel_shuffle: input channels {c_in} not divisible by r*r={r*r}"
        )
    c = c_in // (r * r)
    # Channel reshape uses (C, r, r) so output channel c at sub-pixel (i, j)
    # reads from input channel index `c*r*r + i*r + j` — matches PyTorch.
    # [N, H, W, C, r, r]
    reshaped = x.reshape((n, h, w, c, r, r))
    # Permute: H paired with the i-axis, W paired with the j-axis,
    # C moved to the trailing channel slot.
    # Target axes order: (N, H, r_i, W, r_j, C)
    transposed = mx.transpose(reshaped, (0, 1, 4, 2, 5, 3))
    # [N, H*r, W*r, C]
    return transposed.reshape((n, h * r, w * r, c))


class PixelShuffleBlock(nn.Module):
    """``conv(3×3, F → out*r²)`` followed by NHWC pixel shuffle."""

    def __init__(self, in_channels: int, out_channels: int, scale: int) -> None:
        super().__init__()
        if scale < 1:
            raise ValueError(f"PixelShuffleBlock scale must be >= 1, got {scale}")
        self.conv = _same_conv(in_channels, out_channels * scale * scale, 3)
        self.scale = scale

    def __call__(self, x: mx.array) -> mx.array:
        y = self.conv(x)
        if self.scale == 1:
            return y
        return _pixel_shuffle_nhwc(y, self.scale)


# ----------------------------------------------------------------------------
# EfRLFN
# ----------------------------------------------------------------------------

class EfRLFN(nn.Module):
    """Reference MLX-Python EfRLFN. NHWC in / NHWC out."""

    def __init__(
        self,
        img_channels: int = 3,
        feature_channels: int = 52,
        num_blocks: int = 6,
        scale: int = 4,
    ) -> None:
        super().__init__()
        if num_blocks != 6:
            raise ValueError(
                f"EfRLFN currently locks num_blocks=6 (matches upstream "
                f"block_1..block_6 key scheme); got {num_blocks}"
            )
        if scale < 1:
            raise ValueError(f"scale must be >= 1, got {scale}")

        self.img_channels = img_channels
        self.feature_channels = feature_channels
        self.num_blocks = num_blocks
        self.scale = scale

        self.conv_1 = _same_conv(img_channels, feature_channels, 3)
        self.conv_2 = _same_conv(feature_channels, feature_channels, 3)

        self.block_1 = ERLFB(feature_channels)
        self.block_2 = ERLFB(feature_channels)
        self.block_3 = ERLFB(feature_channels)
        self.block_4 = ERLFB(feature_channels)
        self.block_5 = ERLFB(feature_channels)
        self.block_6 = ERLFB(feature_channels)

        self.upsampler = PixelShuffleBlock(
            in_channels=feature_channels,
            out_channels=img_channels,
            scale=scale,
        )

    def __call__(self, x: mx.array) -> mx.array:
        """Forward pass.

        Args:
            x: ``[N, H, W, img_channels]`` NHWC tensor in ``[0, 1]``.

        Returns:
            ``[N, H * scale, W * scale, img_channels]``.
        """
        out_feature = self.conv_1(x)

        out = self.block_1(out_feature)
        out = self.block_2(out)
        out = self.block_3(out)
        out = self.block_4(out)
        out = self.block_5(out)
        out = self.block_6(out)

        out_low_resolution = self.conv_2(out + out_feature)
        return self.upsampler(out_low_resolution)
