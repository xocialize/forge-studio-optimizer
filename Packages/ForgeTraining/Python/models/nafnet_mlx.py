"""MLX NAFNet — Python reference mirroring the MLX-Swift port.

Numerical oracle for Phase B.4 weight conversion (Task #13). This module is a
1:1 transcription of
``Packages/ForgeOptimizer/Sources/ForgeOptimizer/Restoration/NAFNet.swift`` —
same module attribute names (so the converted safetensors keys load here exactly
as they do in Swift), same NHWC ops, same pixel-shuffle ``(C, r, r)`` channel
split. It is NOT trained here; it only loads converted weights so the parity
test can compare PyTorch (``nafnet_torch``) ↔ MLX before the weights ever reach
Swift.

Key-path contract (matches NAFNet.swift @ModuleInfo flatten):
    intro.{weight,bias}, ending.{weight,bias}
    encoders.<i>.blocks.layers.<j>.<nafblock>,  encoders.<i>.down.{weight,bias}
    middle_blks.layers.<j>.<nafblock>
    decoders.<i>.upConv.weight,  decoders.<i>.blocks.layers.<j>.<nafblock>
  <nafblock> =
    norm1.norm.{weight,bias}, norm2.norm.{weight,bias},
    conv{1..5}.{weight,bias}, sca.conv.{weight,bias}, beta, gamma
"""

from __future__ import annotations

import mlx.core as mx
import mlx.nn as nn


class Conv2d(nn.Module):
    """Conv2d wrapping ``mx.conv2d`` with ``groups`` support (mlx 0.18's
    ``nn.Conv2d`` lacks the kwarg). Weight ``(O, kH, kW, I/groups)`` + optional
    ``bias`` — param names ``weight``/``bias`` match the converter + Swift."""

    def __init__(self, in_ch, out_ch, kernel_size, stride=1, padding=0,
                 groups=1, bias=True):
        super().__init__()
        k = kernel_size if isinstance(kernel_size, tuple) else (kernel_size, kernel_size)
        self.weight = mx.zeros((out_ch, k[0], k[1], in_ch // groups))
        if bias:
            self.bias = mx.zeros((out_ch,))
        self._stride = stride
        self._padding = padding
        self._groups = groups

    def __call__(self, x: mx.array) -> mx.array:
        y = mx.conv2d(x, self.weight, stride=self._stride,
                      padding=self._padding, groups=self._groups)
        if "bias" in self:
            y = y + self.bias
        return y


class _Seq(nn.Module):
    """Minimal Sequential whose children flatten under ``.layers.<j>`` —
    matches the MLX-Swift ``Sequential`` key path (``blocks.layers.0...``)."""

    def __init__(self, layers: list) -> None:
        super().__init__()
        self.layers = layers

    def __call__(self, x: mx.array) -> mx.array:
        for layer in self.layers:
            x = layer(x)
        return x


class LayerNorm2d(nn.Module):
    """Channel-wise LayerNorm. NHWC → normalize over the last (C) axis.
    Wraps ``nn.LayerNorm`` as ``self.norm`` to match the Swift key
    ``normX.norm.{weight,bias}``."""

    def __init__(self, channels: int, eps: float = 1e-6) -> None:
        super().__init__()
        self.norm = nn.LayerNorm(channels, eps=eps)

    def __call__(self, x: mx.array) -> mx.array:
        return self.norm(x)


class SimpleGate(nn.Module):
    def __call__(self, x: mx.array) -> mx.array:
        a, b = mx.split(x, 2, axis=-1)
        return a * b


class SCA(nn.Module):
    """Simplified Channel Attention: global avg-pool (over H,W) → 1×1 conv →
    broadcast-multiply."""

    def __init__(self, channels: int) -> None:
        super().__init__()
        self.conv = Conv2d(channels, channels, kernel_size=1, bias=True)

    def __call__(self, x: mx.array) -> mx.array:
        pooled = mx.mean(x, axis=(1, 2), keepdims=True)  # [N,1,1,C]
        return x * self.conv(pooled)


class NAFBlock(nn.Module):
    def __init__(self, c: int, dw_expand: int = 2, ffn_expand: int = 2) -> None:
        super().__init__()
        dw = c * dw_expand
        ffn = c * ffn_expand

        self.norm1 = LayerNorm2d(c)
        self.norm2 = LayerNorm2d(c)

        self.conv1 = Conv2d(c, dw, kernel_size=1, bias=True)
        self.conv2 = Conv2d(dw, dw, kernel_size=3, padding=1, groups=dw, bias=True)
        self.conv3 = Conv2d(dw // 2, c, kernel_size=1, bias=True)
        self.conv4 = Conv2d(c, ffn, kernel_size=1, bias=True)
        self.conv5 = Conv2d(ffn // 2, c, kernel_size=1, bias=True)

        self.sca = SCA(dw // 2)
        self.sg = SimpleGate()

        # NHWC per-channel residual scales [1,1,1,C], zero-init.
        self.beta = mx.zeros((1, 1, 1, c))
        self.gamma = mx.zeros((1, 1, 1, c))

    def __call__(self, inp: mx.array) -> mx.array:
        x = self.norm1(inp)
        x = self.conv1(x)
        x = self.conv2(x)
        x = self.sg(x)
        x = self.sca(x)
        x = self.conv3(x)
        y = inp + x * self.beta

        z = self.norm2(y)
        z = self.conv4(z)
        z = self.sg(z)
        z = self.conv5(z)
        return y + z * self.gamma


class NAFNetEncoderStage(nn.Module):
    def __init__(self, channels: int, num_blocks: int) -> None:
        super().__init__()
        self.blocks = _Seq([NAFBlock(channels) for _ in range(num_blocks)])
        self.down = Conv2d(channels, channels * 2, kernel_size=2, stride=2, bias=True)


class NAFNetDecoderStage(nn.Module):
    def __init__(self, channels: int, num_blocks: int) -> None:
        super().__init__()
        self.upConv = Conv2d(channels, channels * 2, kernel_size=1, bias=False)
        out_ch = channels // 2
        self.blocks = _Seq([NAFBlock(out_ch) for _ in range(num_blocks)])


def pixel_shuffle_nhwc(x: mx.array, r: int) -> mx.array:
    """[N,H,W,C*r*r] → [N,H*r,W*r,C], channel split (C, r, r) to match
    PyTorch nn.PixelShuffle (see NAFNet.swift::pixelShuffleNHWC)."""
    n, h, w, cin = x.shape
    c = cin // (r * r)
    x = x.reshape(n, h, w, c, r, r)
    x = x.transpose(0, 1, 4, 2, 5, 3)  # [N, H, r_i, W, r_j, C]
    return x.reshape(n, h * r, w * r, c)


class NAFNet(nn.Module):
    """U-Net restoration net. NHWC. Mirrors NAFNet.swift."""

    def __init__(
        self,
        img_channels: int = 3,
        width: int = 24,
        middle_blk_num: int = 1,
        enc_blk_nums: tuple[int, ...] = (1, 1, 1, 1),
        dec_blk_nums: tuple[int, ...] = (1, 1, 1, 1),
    ) -> None:
        super().__init__()
        assert len(enc_blk_nums) == len(dec_blk_nums)
        self.padder_size = 1 << len(enc_blk_nums)

        self.intro = Conv2d(img_channels, width, kernel_size=3, padding=1, bias=True)
        self.ending = Conv2d(width, img_channels, kernel_size=3, padding=1, bias=True)

        encoders = []
        chan = width
        for n in enc_blk_nums:
            encoders.append(NAFNetEncoderStage(chan, n))
            chan *= 2
        self.encoders = encoders

        self.middle_blks = _Seq([NAFBlock(chan) for _ in range(middle_blk_num)])

        decoders = []
        for n in dec_blk_nums:
            decoders.append(NAFNetDecoderStage(chan, n))
            chan //= 2
        self.decoders = decoders

    def __call__(self, x: mx.array) -> mx.array:
        _, h0, w0, _ = x.shape
        x = self._pad(x)

        h = self.intro(x)
        skips = []
        for enc in self.encoders:
            h = enc.blocks(h)
            skips.append(h)
            h = enc.down(h)

        h = self.middle_blks(h)

        for i, dec in enumerate(self.decoders):
            skip = skips[len(skips) - 1 - i]
            h = dec.upConv(h)
            h = pixel_shuffle_nhwc(h, 2)
            h = h + skip
            h = dec.blocks(h)

        h = self.ending(h)
        h = h + x
        return h[:, :h0, :w0, :]

    def _pad(self, x: mx.array) -> mx.array:
        _, h, w, _ = x.shape
        ph = (self.padder_size - h % self.padder_size) % self.padder_size
        pw = (self.padder_size - w % self.padder_size) % self.padder_size
        if ph == 0 and pw == 0:
            return x
        return mx.pad(x, [(0, 0), (0, ph), (0, pw), (0, 0)])
