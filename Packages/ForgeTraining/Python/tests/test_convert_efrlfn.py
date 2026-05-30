"""
Unit tests for ``Scripts.convert_efrlfn_to_mlx.convert_state_dict``.

These tests work without PyTorch installed: the conversion function accepts
both ``torch.Tensor`` and ``numpy.ndarray`` inputs, so we build the synthetic
"state dict" out of NumPy arrays. The full PyTorch ↔ MLX parity check lives in
``test_efrlfn_parity.py`` and uses ``pytest.importorskip("torch")``.

Coverage:
    - Key remap: ``upsampler.0.{weight,bias}`` → ``upsampler.conv.{weight,bias}``
    - Conv2d transpose: ``(O, I, kH, kW)`` → ``(O, kH, kW, I)``
    - Conv1d transpose: ``(O, I, k)`` → ``(O, k, I)``
    - Bias passthrough (no transpose)
    - Dtype handling (float32 / float16)
    - Round-trip via mx.load_safetensors recovers identical key set + values
    - ``main()`` runs end-to-end on a synthetic checkpoint
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

import mlx.core as mx

# Make Packages/ForgeTraining/ importable when running pytest from the repo.
HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent.parent.parent))  # Packages/ForgeTraining/

from Scripts.convert_efrlfn_to_mlx import (  # noqa: E402
    EXPECTED_PARAM_COUNT,
    _remap_key,
    convert_state_dict,
    save_mlx_weights,
)


# ----------------------------------------------------------------------------
# Synthetic state-dict builder — mirrors the upstream EfRLFN key scheme.
# ----------------------------------------------------------------------------

def _synthetic_state_dict(
    feature_channels: int = 52,
    in_channels: int = 3,
    out_channels: int = 3,
    scale: int = 4,
    seed: int = 0,
) -> dict[str, np.ndarray]:
    """Build a numpy state-dict shaped like the upstream EfRLFN checkpoint.

    Uses deterministic linspace values so per-axis values are unique — that
    way a wrong transpose shows up as a value mismatch, not just a shape one.
    """
    rng = np.random.default_rng(seed)
    sd: dict[str, np.ndarray] = {}

    def _conv2d(out_c: int, in_c: int, k: int, key: str) -> None:
        sd[f"{key}.weight"] = rng.standard_normal(
            (out_c, in_c, k, k), dtype=np.float32
        )
        sd[f"{key}.bias"] = rng.standard_normal((out_c,), dtype=np.float32)

    def _conv1d(out_c: int, in_c: int, k: int, key: str) -> None:
        sd[f"{key}.weight"] = rng.standard_normal(
            (out_c, in_c, k), dtype=np.float32
        )

    _conv2d(feature_channels, in_channels, 3, "conv_1")
    for i in range(1, 7):
        _conv2d(feature_channels, feature_channels, 3, f"block_{i}.c1_r")
        _conv2d(feature_channels, feature_channels, 3, f"block_{i}.c2_r")
        _conv2d(feature_channels, feature_channels, 3, f"block_{i}.c3_r")
        _conv2d(feature_channels, feature_channels, 1, f"block_{i}.c5")
        _conv1d(1, 1, 3, f"block_{i}.eca.conv")
    _conv2d(feature_channels, feature_channels, 3, "conv_2")
    _conv2d(out_channels * scale * scale, feature_channels, 3, "upsampler.0")

    return sd


# ----------------------------------------------------------------------------
# Key remap
# ----------------------------------------------------------------------------

class TestRemapKey:

    def test_upsampler_zero_to_named_conv(self) -> None:
        assert _remap_key("upsampler.0.weight") == "upsampler.conv.weight"
        assert _remap_key("upsampler.0.bias") == "upsampler.conv.bias"

    def test_other_keys_unchanged(self) -> None:
        for key in [
            "conv_1.weight",
            "conv_1.bias",
            "conv_2.weight",
            "block_1.c1_r.weight",
            "block_3.c5.bias",
            "block_6.eca.conv.weight",
        ]:
            assert _remap_key(key) == key

    def test_no_double_zero_substring_false_positive(self) -> None:
        # Ensure the remap doesn't accidentally fire on unrelated keys that
        # happen to contain "upsampler.0" as a substring of something else.
        # (No such keys exist upstream, but guard against future patterns.)
        assert _remap_key("not_upsampler.0.weight") == "not_upsampler.0.weight"


# ----------------------------------------------------------------------------
# convert_state_dict
# ----------------------------------------------------------------------------

class TestConvertStateDict:

    def test_param_count_matches_expected_for_scale_4(self) -> None:
        sd = _synthetic_state_dict(scale=4)
        total = sum(int(np.prod(v.shape)) for v in sd.values())
        assert total == EXPECTED_PARAM_COUNT[4], (
            f"synthetic state dict total {total} != upstream-pinned "
            f"{EXPECTED_PARAM_COUNT[4]}"
        )

    def test_param_count_matches_expected_for_scale_2(self) -> None:
        sd = _synthetic_state_dict(scale=2)
        total = sum(int(np.prod(v.shape)) for v in sd.values())
        assert total == EXPECTED_PARAM_COUNT[2], (
            f"synthetic state dict total {total} != upstream-pinned "
            f"{EXPECTED_PARAM_COUNT[2]}"
        )

    def test_conv2d_weight_transpose(self) -> None:
        sd = {"conv_1.weight": np.zeros((48, 3, 3, 3), dtype=np.float32)}
        out = convert_state_dict(sd)
        assert "conv_1.weight" in out
        assert out["conv_1.weight"].shape == (48, 3, 3, 3), (
            "Conv2d transpose: PyTorch (O, I, kH, kW) → MLX (O, kH, kW, I); "
            "axis order verified below."
        )

    def test_conv2d_transpose_preserves_values_at_correct_axes(self) -> None:
        # Build a PyTorch-layout weight with axis-tagged values so we can
        # verify the *axis permutation*, not just the shape.
        # PT shape (O=2, I=3, kH=4, kW=5).
        O, I, kH, kW = 2, 3, 4, 5
        pt = np.zeros((O, I, kH, kW), dtype=np.float32)
        for o in range(O):
            for i in range(I):
                for h in range(kH):
                    for w in range(kW):
                        # Encode (o,i,h,w) as a unique scalar.
                        pt[o, i, h, w] = o * 1000 + i * 100 + h * 10 + w
        out = convert_state_dict({"conv_1.weight": pt})
        mx_arr = np.array(out["conv_1.weight"])  # MLX → numpy view
        assert mx_arr.shape == (O, kH, kW, I), (
            f"shape after transpose: {mx_arr.shape}, want (O, kH, kW, I) = "
            f"({O}, {kH}, {kW}, {I})"
        )
        # The value at MLX (o, h, w, i) must equal PT (o, i, h, w).
        for o in range(O):
            for i in range(I):
                for h in range(kH):
                    for w in range(kW):
                        assert mx_arr[o, h, w, i] == pt[o, i, h, w], (
                            f"axis mismatch at o={o} h={h} w={w} i={i}: "
                            f"mlx={mx_arr[o,h,w,i]} pt={pt[o,i,h,w]}"
                        )

    def test_conv1d_weight_transpose(self) -> None:
        sd = {"block_1.eca.conv.weight": np.zeros((1, 1, 3), dtype=np.float32)}
        out = convert_state_dict(sd)
        # PT Conv1d (O, I, k) → MLX (O, k, I). Square shape (1,1,3) → (1,3,1)
        assert out["block_1.eca.conv.weight"].shape == (1, 3, 1)

    def test_bias_passthrough(self) -> None:
        # 1-D arrays must not be transposed.
        bias = np.array([1.0, 2.0, 3.0, 4.0], dtype=np.float32)
        out = convert_state_dict({"conv_1.bias": bias})
        np.testing.assert_array_equal(np.array(out["conv_1.bias"]), bias)

    def test_upsampler_key_remap(self) -> None:
        sd = {
            "upsampler.0.weight": np.zeros((48, 52, 3, 3), dtype=np.float32),
            "upsampler.0.bias": np.zeros((48,), dtype=np.float32),
        }
        out = convert_state_dict(sd)
        assert "upsampler.conv.weight" in out
        assert "upsampler.conv.bias" in out
        assert "upsampler.0.weight" not in out
        assert "upsampler.0.bias" not in out

    def test_full_state_dict_has_60_keys(self) -> None:
        # Upstream EfRLFN(scale=4) ships exactly 60 keys; verify the converter
        # neither drops nor invents any.
        sd = _synthetic_state_dict(scale=4)
        out = convert_state_dict(sd)
        assert len(out) == len(sd) == 60

    def test_dtype_float16(self) -> None:
        sd = {"conv_1.weight": np.ones((4, 3, 3, 3), dtype=np.float32)}
        out = convert_state_dict(sd, dtype="float16")
        assert out["conv_1.weight"].dtype == mx.float16

    def test_dtype_float32(self) -> None:
        sd = {"conv_1.weight": np.ones((4, 3, 3, 3), dtype=np.float32)}
        out = convert_state_dict(sd, dtype="float32")
        assert out["conv_1.weight"].dtype == mx.float32

    def test_dtype_rejects_unknown(self) -> None:
        with pytest.raises(ValueError):
            convert_state_dict({}, dtype="float64")

    def test_rejects_unsupported_value_type(self) -> None:
        with pytest.raises(TypeError):
            # str isn't a numpy array or a torch tensor.
            convert_state_dict({"conv_1.weight": "nope"})  # type: ignore[arg-type]

    def test_all_outputs_are_mx_arrays(self) -> None:
        sd = _synthetic_state_dict(scale=4)
        out = convert_state_dict(sd)
        for k, v in out.items():
            assert isinstance(v, mx.array), f"{k}: got {type(v).__name__}"


# ----------------------------------------------------------------------------
# Save / round-trip
# ----------------------------------------------------------------------------

class TestRoundTrip:

    def test_save_then_load_recovers_identical_keys(self, tmp_path: Path) -> None:
        sd = _synthetic_state_dict(scale=4)
        mlx_state = convert_state_dict(sd)
        out_path = tmp_path / "round_trip.safetensors"
        save_mlx_weights(mlx_state, out_path)

        reread = mx.load(str(out_path))
        assert set(reread.keys()) == set(mlx_state.keys())

    def test_save_then_load_recovers_values(self, tmp_path: Path) -> None:
        sd = _synthetic_state_dict(scale=4)
        mlx_state = convert_state_dict(sd)
        out_path = tmp_path / "values.safetensors"
        save_mlx_weights(mlx_state, out_path)

        reread = mx.load(str(out_path))
        for k in mlx_state:
            a = np.array(mlx_state[k])
            b = np.array(reread[k])
            assert a.shape == b.shape
            assert a.dtype == b.dtype
            np.testing.assert_array_equal(a, b)

    def test_saved_file_loads_into_mlx_python_model(self, tmp_path: Path) -> None:
        """Smoke-test the deliverable: the converted file loads into the MLX
        reference model with no unused keys (this is the Python proxy for
        what Swift's ``update(verify: .noUnusedKeys)`` will do at runtime).
        """
        from Python.models.efrlfn_mlx import EfRLFN

        sd = _synthetic_state_dict(scale=4)
        mlx_state = convert_state_dict(sd)
        out_path = tmp_path / "load_into_model.safetensors"
        save_mlx_weights(mlx_state, out_path)

        model = EfRLFN(scale=4)
        loaded = mx.load(str(out_path))
        model.load_weights(list(loaded.items()))

        # Build the model's flat key set and check exact equality.
        from mlx.utils import tree_flatten
        model_keys = {k for k, _ in tree_flatten(model.parameters())}
        file_keys = set(loaded.keys())
        assert model_keys == file_keys, (
            f"\nmodel-only keys: {sorted(model_keys - file_keys)}\n"
            f"file-only keys:  {sorted(file_keys - model_keys)}"
        )

    def test_forward_pass_runs_after_load(self, tmp_path: Path) -> None:
        from Python.models.efrlfn_mlx import EfRLFN

        sd = _synthetic_state_dict(scale=4)
        mlx_state = convert_state_dict(sd)
        out_path = tmp_path / "forward.safetensors"
        save_mlx_weights(mlx_state, out_path)

        model = EfRLFN(scale=4)
        loaded = mx.load(str(out_path))
        model.load_weights(list(loaded.items()))

        x = mx.zeros((1, 16, 16, 3))
        y = model(x)
        mx.eval(y)
        assert y.shape == (1, 64, 64, 3)


# ----------------------------------------------------------------------------
# CLI smoke
# ----------------------------------------------------------------------------

class TestMainCLI:

    def test_main_end_to_end_on_synthetic_checkpoint(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Exercise ``main()`` on a synthetic .pt without touching the network."""
        torch = pytest.importorskip("torch", exc_type=ImportError)

        sd = _synthetic_state_dict(scale=4)
        pt_sd = {k: torch.from_numpy(v) for k, v in sd.items()}
        pt_path = tmp_path / "synthetic.pt"
        torch.save(pt_sd, pt_path)

        out_path = tmp_path / "synthetic.safetensors"

        from Scripts.convert_efrlfn_to_mlx import main
        rc = main([
            "--input", str(pt_path),
            "--output", str(out_path),
            "--scale", "4",
        ])
        assert rc == 0
        assert out_path.exists()
        reread = mx.load(str(out_path))
        assert len(reread) == 60
