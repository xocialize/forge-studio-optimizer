"""Unit tests for ``Scripts.convert_nafnet_to_mlx`` — no PyTorch required.

``convert_state_dict`` accepts numpy arrays, so the synthetic "state dict" is
built from numpy. The full PyTorch↔MLX parity check is in
``test_nafnet_parity.py`` (uses ``pytest.importorskip("torch")``).

Coverage:
    - remap_key: every container rename + the norm→norm.norm wrap
    - Conv2d transpose (O,I,kH,kW)→(O,kH,kW,I), incl. depthwise (dw,1,3,3)
    - beta/gamma reshape (1,C,1,1)→(1,1,1,C)
    - LayerNorm weight/bias + conv bias passthrough (1-D)
    - dtype float16/float32
    - round-trip via mx.load recovers the key set
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest
import mlx.core as mx

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent.parent.parent))  # Packages/ForgeTraining/

from Scripts.convert_nafnet_to_mlx import (  # noqa: E402
    convert_state_dict,
    remap_key,
    save_mlx_weights,
)


def test_remap_key_table():
    cases = {
        "intro.weight": "intro.weight",
        "ending.bias": "ending.bias",
        "encoders.0.0.conv1.weight": "encoders.0.blocks.layers.0.conv1.weight",
        "encoders.2.0.norm1.weight": "encoders.2.blocks.layers.0.norm1.norm.weight",
        "encoders.0.0.norm2.bias": "encoders.0.blocks.layers.0.norm2.norm.bias",
        "encoders.0.0.sca.conv.weight": "encoders.0.blocks.layers.0.sca.conv.weight",
        "encoders.0.0.beta": "encoders.0.blocks.layers.0.beta",
        "downs.1.weight": "encoders.1.down.weight",
        "downs.1.bias": "encoders.1.down.bias",
        "ups.0.0.weight": "decoders.0.upConv.weight",
        "decoders.3.0.conv5.bias": "decoders.3.blocks.layers.0.conv5.bias",
        "middle_blks.0.gamma": "middle_blks.layers.0.gamma",
        "middle_blks.0.norm1.weight": "middle_blks.layers.0.norm1.norm.weight",
    }
    for pt, expect in cases.items():
        assert remap_key(pt) == expect, f"{pt} -> {remap_key(pt)} (want {expect})"


def test_remap_unmapped_raises():
    with pytest.raises(KeyError):
        remap_key("totally.bogus.key")


def test_conv_transpose_standard():
    # (O=5, I=4, kH=3, kW=2) -> (5, 3, 2, 4)
    w = np.arange(5 * 4 * 3 * 2, dtype=np.float32).reshape(5, 4, 3, 2)
    out = convert_state_dict({"intro.weight": w}, dtype="float32")
    arr = np.array(out["intro.weight"])
    assert arr.shape == (5, 3, 2, 4)
    assert np.allclose(arr, np.transpose(w, (0, 2, 3, 1)))


def test_conv_transpose_depthwise():
    # depthwise (dw=8, 1, 3, 3) -> (8, 3, 3, 1)
    w = np.random.default_rng(0).standard_normal((8, 1, 3, 3)).astype(np.float32)
    out = convert_state_dict({"encoders.0.0.conv2.weight": w}, dtype="float32")
    arr = np.array(out["encoders.0.blocks.layers.0.conv2.weight"])
    assert arr.shape == (8, 3, 3, 1)
    assert np.allclose(arr, np.transpose(w, (0, 2, 3, 1)))


def test_beta_gamma_reshape():
    beta = np.random.default_rng(1).standard_normal((1, 6, 1, 1)).astype(np.float32)
    out = convert_state_dict({"encoders.0.0.beta": beta}, dtype="float32")
    arr = np.array(out["encoders.0.blocks.layers.0.beta"])
    assert arr.shape == (1, 1, 1, 6)
    assert np.allclose(arr.reshape(-1), beta.reshape(-1))


def test_1d_passthrough():
    # LayerNorm weight (c,) and conv bias (O,) stay 1-D, values unchanged.
    nw = np.linspace(0, 1, 6, dtype=np.float32)
    cb = np.linspace(-1, 1, 5, dtype=np.float32)
    out = convert_state_dict(
        {"encoders.0.0.norm1.weight": nw, "intro.bias": cb}, dtype="float32")
    assert np.allclose(np.array(out["encoders.0.blocks.layers.0.norm1.norm.weight"]), nw)
    assert np.allclose(np.array(out["intro.bias"]), cb)


@pytest.mark.parametrize("dtype,np_dtype", [("float32", np.float32), ("float16", np.float16)])
def test_dtype(dtype, np_dtype):
    w = np.ones((2, 3, 1, 1), dtype=np.float32)
    out = convert_state_dict({"ups.0.0.weight": w}, dtype=dtype)
    arr = np.array(out["decoders.0.upConv.weight"])
    assert arr.dtype == np_dtype


def test_roundtrip_keyset(tmp_path):
    sd = {
        "intro.weight": np.zeros((4, 3, 3, 3), np.float32),
        "intro.bias": np.zeros((4,), np.float32),
        "encoders.0.0.conv2.weight": np.zeros((8, 1, 3, 3), np.float32),
        "encoders.0.0.beta": np.zeros((1, 4, 1, 1), np.float32),
        "downs.0.weight": np.zeros((8, 4, 2, 2), np.float32),
    }
    out = convert_state_dict(sd, dtype="float16")
    path = tmp_path / "n.safetensors"
    save_mlx_weights(out, path)
    reloaded = mx.load(str(path))
    assert set(reloaded.keys()) == set(out.keys())
