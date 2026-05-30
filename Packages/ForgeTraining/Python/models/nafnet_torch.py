"""PyTorch NAFNet — training reference for Phase B.3.

Faithful to the MLX-Swift port in
``Packages/ForgeOptimizer/Sources/ForgeOptimizer/Restoration/NAFNet.swift`` and to
upstream `megvii-research/NAFNet` (MIT). Trained here in PyTorch (MPS on Apple
Silicon), then B.4 converts the state_dict to MLX safetensors via the standard
``convert_*_to_mlx.py`` pattern (conv ``(O,I,kH,kW)`` → ``(O,kH,kW,I)``).

Default config is the ADR-0003 rescope: ``width=24, enc=[1,1,1,1],
middle=1, dec=[1,1,1,1]`` (~2.5M params, ~5 MB FP16 (matches the Swift port; ADR-0003 prose "1.4M" was an under-estimate)) so the ForgeOptimizer
bundle stays under the §4 ``bundle_size_max`` gate. The wider
``width=32, [2,2,2,2]`` config is reachable via constructor args if B.3
acceptance shows the default underfits (ADR-0003 revisit trigger).

Architecture (per NAFBlock):
    x = LayerNorm(inp)
    x = conv1x1 (c -> dw*c); x = dwconv3x3 (groups=dw*c)
    x = SimpleGate (dw*c -> dw*c/2); x = SCA(x) * x; x = conv1x1 (-> c)
    y = inp + x * beta
    x = LayerNorm(y); x = conv1x1 (c -> ffn*c); x = SimpleGate; x = conv1x1 (-> c)
    out = y + x * gamma
"""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


class LayerNorm2d(nn.Module):
    """Channel-wise LayerNorm over NCHW (normalizes over the C axis)."""

    def __init__(self, channels: int, eps: float = 1e-6) -> None:
        super().__init__()
        self.weight = nn.Parameter(torch.ones(channels))
        self.bias = nn.Parameter(torch.zeros(channels))
        self.eps = eps

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: [N, C, H, W]; normalize across C.
        mu = x.mean(dim=1, keepdim=True)
        var = (x - mu).pow(2).mean(dim=1, keepdim=True)
        x = (x - mu) / torch.sqrt(var + self.eps)
        return x * self.weight[None, :, None, None] + self.bias[None, :, None, None]


class SimpleGate(nn.Module):
    """Split channels in half and element-wise multiply the two halves."""

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        a, b = x.chunk(2, dim=1)
        return a * b


class SimplifiedChannelAttention(nn.Module):
    """SCA: global avg-pool -> 1x1 conv -> broadcast multiply."""

    def __init__(self, channels: int) -> None:
        super().__init__()
        self.pool = nn.AdaptiveAvgPool2d(1)
        self.conv = nn.Conv2d(channels, channels, kernel_size=1, bias=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x * self.conv(self.pool(x))


class NAFBlock(nn.Module):
    def __init__(self, c: int, dw_expand: int = 2, ffn_expand: int = 2) -> None:
        super().__init__()
        dw = c * dw_expand
        self.norm1 = LayerNorm2d(c)
        self.conv1 = nn.Conv2d(c, dw, kernel_size=1, bias=True)
        self.conv2 = nn.Conv2d(dw, dw, kernel_size=3, padding=1, groups=dw, bias=True)
        self.sg = SimpleGate()
        self.sca = SimplifiedChannelAttention(dw // 2)
        self.conv3 = nn.Conv2d(dw // 2, c, kernel_size=1, bias=True)

        ffn = c * ffn_expand
        self.norm2 = LayerNorm2d(c)
        self.conv4 = nn.Conv2d(c, ffn, kernel_size=1, bias=True)
        self.conv5 = nn.Conv2d(ffn // 2, c, kernel_size=1, bias=True)

        self.beta = nn.Parameter(torch.zeros(1, c, 1, 1))
        self.gamma = nn.Parameter(torch.zeros(1, c, 1, 1))

    def forward(self, inp: torch.Tensor) -> torch.Tensor:
        x = self.norm1(inp)
        x = self.conv1(x)
        x = self.conv2(x)
        x = self.sg(x)
        x = self.sca(x)
        x = self.conv3(x)
        y = inp + x * self.beta

        x = self.norm2(y)
        x = self.conv4(x)
        x = self.sg(x)
        x = self.conv5(x)
        return y + x * self.gamma


class NAFNet(nn.Module):
    def __init__(
        self,
        img_channels: int = 3,
        width: int = 24,
        enc_blk_nums: tuple[int, ...] = (1, 1, 1, 1),
        middle_blk_num: int = 1,
        dec_blk_nums: tuple[int, ...] = (1, 1, 1, 1),
    ) -> None:
        super().__init__()
        self.intro = nn.Conv2d(img_channels, width, kernel_size=3, padding=1, bias=True)
        self.ending = nn.Conv2d(width, img_channels, kernel_size=3, padding=1, bias=True)

        self.encoders = nn.ModuleList()
        self.downs = nn.ModuleList()
        self.decoders = nn.ModuleList()
        self.ups = nn.ModuleList()

        chan = width
        for n in enc_blk_nums:
            self.encoders.append(nn.Sequential(*[NAFBlock(chan) for _ in range(n)]))
            self.downs.append(nn.Conv2d(chan, 2 * chan, kernel_size=2, stride=2, bias=True))
            chan *= 2

        self.middle_blks = nn.Sequential(*[NAFBlock(chan) for _ in range(middle_blk_num)])

        for n in dec_blk_nums:
            self.ups.append(
                nn.Sequential(
                    nn.Conv2d(chan, chan * 2, kernel_size=1, bias=False),
                    nn.PixelShuffle(2),
                )
            )
            chan //= 2
            self.decoders.append(nn.Sequential(*[NAFBlock(chan) for _ in range(n)]))

        self.padder_size = 2 ** len(self.encoders)

    def forward(self, inp: torch.Tensor) -> torch.Tensor:
        _, _, h, w = inp.shape
        inp = self._check_image_size(inp)

        x = self.intro(inp)
        skips = []
        for encoder, down in zip(self.encoders, self.downs):
            x = encoder(x)
            skips.append(x)
            x = down(x)

        x = self.middle_blks(x)

        for decoder, up, skip in zip(self.decoders, self.ups, skips[::-1]):
            x = up(x)
            x = x + skip
            x = decoder(x)

        x = self.ending(x)
        x = x + inp[:, : x.shape[1]]
        return x[:, :, :h, :w]

    def _check_image_size(self, x: torch.Tensor) -> torch.Tensor:
        _, _, h, w = x.shape
        ph = (self.padder_size - h % self.padder_size) % self.padder_size
        pw = (self.padder_size - w % self.padder_size) % self.padder_size
        return F.pad(x, (0, pw, 0, ph))


def build_default() -> NAFNet:
    """The ADR-0003 default (width=24, [1,1,1,1])."""
    return NAFNet()


def count_params(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters() if p.requires_grad)


if __name__ == "__main__":
    m = build_default()
    n = count_params(m)
    x = torch.randn(1, 3, 256, 256)
    y = m(x)
    print(f"NAFNet default: {n/1e6:.2f}M params, in {tuple(x.shape)} -> out {tuple(y.shape)}")
    assert y.shape == x.shape
    # Verified 2.54M, identical structure to the Swift NAFNet port (test band 0.5-3M).
    assert 0.8e6 < n < 3.0e6, f"param count {n} outside ADR-0003 band"
