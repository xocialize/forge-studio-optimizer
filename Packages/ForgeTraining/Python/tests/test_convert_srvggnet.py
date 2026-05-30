"""
Unit tests for ``Scripts.convert_srvggnet_to_mlx.convert_state_dict`` and the
index-aware ``_remap_key`` for the three vendored SRVGGNetCompact variants.

Works without PyTorch installed: the converter accepts both ``torch.Tensor``
and ``numpy.ndarray`` inputs, so the synthetic state dicts here are pure
NumPy. PyTorch ↔ MLX numerical parity lives in ``test_srvggnet_parity.py``
(uses ``pytest.importorskip("torch")``).

Coverage:
    - Index-aware key remap: body.{N} → first_conv / first_act /
      body_pairs.{k}.{conv|act} / last_conv, with the trailing index
      depending on ``num_conv`` per variant.
    - Conv2d transpose: ``(O, I, kH, kW)`` → ``(O, kH, kW, I)``
    - PReLU + bias 1-D passthrough
    - Dtype handling (float32 / float16)
    - Round-trip via mx.load recovers identical key set + values
    - Variant-config mapping (general / general-wdn / anime)
    - CLI smoke (skipped if torch is missing)
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

import mlx.core as mx

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent.parent.parent))  # Packages/ForgeTraining/

from Scripts.convert_srvggnet_to_mlx import (  # noqa: E402
    VARIANTS,
    VariantSpec,
    _remap_key,
    convert_state_dict,
    save_mlx_weights,
)


# ----------------------------------------------------------------------------
# Synthetic state-dict builder — mirrors the upstream SRVGGNetCompact key
# scheme indexed by integer ``body.N``.
# ----------------------------------------------------------------------------

def _synthetic_state_dict(variant: str, seed: int = 0) -> dict[str, np.ndarray]:
    """Build a numpy state-dict shaped like the upstream checkpoint.

    Layout (per upstream `srvgg_arch.py`):
        body.0:   Conv2d(3 → num_feat) weight + bias
        body.1:   PReLU(num_feat) weight
        body.2,3: Conv2d(F→F) + PReLU(F)  — repeated num_conv times
        ...
        body.{2*num_conv+2}: Conv2d(F → 3*r²) weight + bias
    """
    spec = VARIANTS[variant]
    rng = np.random.default_rng(seed)
    sd: dict[str, np.ndarray] = {}

    F = spec.num_feat
    R = spec.upscale

    def _conv2d(out_c: int, in_c: int, k: int, idx: int) -> None:
        sd[f"body.{idx}.weight"] = rng.standard_normal(
            (out_c, in_c, k, k), dtype=np.float32
        )
        sd[f"body.{idx}.bias"] = rng.standard_normal((out_c,), dtype=np.float32)

    def _prelu(channels: int, idx: int) -> None:
        # PyTorch's PReLU.weight defaults to 0.25 but the value doesn't
        # affect shape — random init keeps the per-axis-tag invariant.
        sd[f"body.{idx}.weight"] = rng.standard_normal((channels,), dtype=np.float32)

    _conv2d(F, 3, 3, 0)
    _prelu(F, 1)
    for k in range(1, spec.num_conv + 1):
        _conv2d(F, F, 3, 2 * k)
        _prelu(F, 2 * k + 1)
    _conv2d(3 * R * R, F, 3, spec.body_last_index)

    return sd


# ----------------------------------------------------------------------------
# VariantSpec sanity
# ----------------------------------------------------------------------------

class TestVariantSpec:

    def test_three_variants_registered(self) -> None:
        assert set(VARIANTS.keys()) == {"general", "general-wdn", "anime"}

    @pytest.mark.parametrize("name,nc", [
        ("general", 32),
        ("general-wdn", 32),
        ("anime", 16),
    ])
    def test_num_conv_per_variant(self, name: str, nc: int) -> None:
        assert VARIANTS[name].num_conv == nc

    @pytest.mark.parametrize("name", ["general", "general-wdn", "anime"])
    def test_act_type_is_prelu(self, name: str) -> None:
        # All three v3 checkpoints train with PReLU. Guard against drift.
        assert VARIANTS[name].act_type == "prelu"

    @pytest.mark.parametrize("name", ["general", "general-wdn", "anime"])
    def test_num_feat_is_64(self, name: str) -> None:
        assert VARIANTS[name].num_feat == 64

    @pytest.mark.parametrize("name,p", [
        ("general", 1_213_296),
        ("general-wdn", 1_213_296),
        ("anime", 621_424),
    ])
    def test_expected_params(self, name: str, p: int) -> None:
        assert VARIANTS[name].expected_params == p

    def test_body_last_index_matches_layout(self) -> None:
        # last conv lives at body.{2 + 2*num_conv}.
        # general: 2 + 64 = 66; anime: 2 + 32 = 34.
        assert VARIANTS["general"].body_last_index == 66
        assert VARIANTS["general-wdn"].body_last_index == 66
        assert VARIANTS["anime"].body_last_index == 34


# ----------------------------------------------------------------------------
# Key remap — the index-aware translator
# ----------------------------------------------------------------------------

class TestRemapKey:

    @pytest.mark.parametrize("variant", ["general", "general-wdn", "anime"])
    def test_first_conv_remap(self, variant: str) -> None:
        spec = VARIANTS[variant]
        assert _remap_key("body.0.weight", spec) == "first_conv.weight"
        assert _remap_key("body.0.bias", spec) == "first_conv.bias"

    @pytest.mark.parametrize("variant", ["general", "general-wdn", "anime"])
    def test_first_act_remap(self, variant: str) -> None:
        spec = VARIANTS[variant]
        # PReLU only ships .weight (no bias).
        assert _remap_key("body.1.weight", spec) == "first_act.weight"

    @pytest.mark.parametrize("variant", ["general", "general-wdn", "anime"])
    def test_last_conv_remap(self, variant: str) -> None:
        spec = VARIANTS[variant]
        last = spec.body_last_index
        assert _remap_key(f"body.{last}.weight", spec) == "last_conv.weight"
        assert _remap_key(f"body.{last}.bias", spec) == "last_conv.bias"

    def test_body_pair_remap_general(self) -> None:
        spec = VARIANTS["general"]
        # First pair conv → body_pairs.0.conv, first pair act → body_pairs.0.act.
        assert _remap_key("body.2.weight", spec) == "body_pairs.0.conv.weight"
        assert _remap_key("body.2.bias", spec) == "body_pairs.0.conv.bias"
        assert _remap_key("body.3.weight", spec) == "body_pairs.0.act.weight"
        # Mid-body sanity.
        assert _remap_key("body.10.weight", spec) == "body_pairs.4.conv.weight"
        assert _remap_key("body.11.weight", spec) == "body_pairs.4.act.weight"
        # Last pair before final conv. num_conv=32 → last pair is index 31,
        # at body.64 (conv) / body.65 (act).
        assert _remap_key("body.64.weight", spec) == "body_pairs.31.conv.weight"
        assert _remap_key("body.65.weight", spec) == "body_pairs.31.act.weight"

    def test_body_pair_remap_anime(self) -> None:
        spec = VARIANTS["anime"]
        # num_conv=16, so last body-pair is index 15 at body.32/body.33.
        assert _remap_key("body.32.weight", spec) == "body_pairs.15.conv.weight"
        assert _remap_key("body.33.weight", spec) == "body_pairs.15.act.weight"

    def test_unknown_prefix_passes_through(self) -> None:
        # Defensive: future upstream variants may grow new keys. Don't crash
        # — let the verify_parity / .noUnusedKeys catch them.
        spec = VARIANTS["general"]
        assert _remap_key("upsampler.weight", spec) == "upsampler.weight"


# ----------------------------------------------------------------------------
# convert_state_dict
# ----------------------------------------------------------------------------

class TestConvertStateDict:

    @pytest.mark.parametrize("variant,expected", [
        ("general", 1_213_296),
        ("general-wdn", 1_213_296),
        ("anime", 621_424),
    ])
    def test_param_count_matches_expected(self, variant: str, expected: int) -> None:
        sd = _synthetic_state_dict(variant)
        total = sum(int(np.prod(v.shape)) for v in sd.values())
        assert total == expected, (
            f"synthetic state dict total {total} != upstream-pinned {expected} "
            f"for variant={variant}"
        )

    def test_conv2d_transpose_preserves_values(self) -> None:
        # PT shape (O=2, I=3, kH=4, kW=5) with axis-tagged values.
        O, I, kH, kW = 2, 3, 4, 5
        pt = np.zeros((O, I, kH, kW), dtype=np.float32)
        for o in range(O):
            for i in range(I):
                for h in range(kH):
                    for w in range(kW):
                        pt[o, i, h, w] = o * 1000 + i * 100 + h * 10 + w
        # Use first_conv key — variant doesn't matter for shape semantics.
        out = convert_state_dict({"body.0.weight": pt}, "general")
        mx_arr = np.array(out["first_conv.weight"])
        assert mx_arr.shape == (O, kH, kW, I), (
            f"shape after transpose: {mx_arr.shape}, want (O, kH, kW, I) = "
            f"({O}, {kH}, {kW}, {I})"
        )
        for o in range(O):
            for i in range(I):
                for h in range(kH):
                    for w in range(kW):
                        assert mx_arr[o, h, w, i] == pt[o, i, h, w], (
                            f"axis mismatch at o={o} h={h} w={w} i={i}"
                        )

    def test_prelu_weight_passthrough(self) -> None:
        # 1-D arrays must not be transposed.
        w = np.array([0.1, 0.2, 0.3, 0.4], dtype=np.float32)
        out = convert_state_dict({"body.1.weight": w}, "general")
        np.testing.assert_array_equal(np.array(out["first_act.weight"]), w)

    def test_bias_passthrough(self) -> None:
        b = np.array([1.0, 2.0, 3.0, 4.0], dtype=np.float32)
        out = convert_state_dict({"body.0.bias": b}, "general")
        np.testing.assert_array_equal(np.array(out["first_conv.bias"]), b)

    def test_wrapped_params_unwrapping(self) -> None:
        # Upstream Real-ESRGAN ships state-dicts wrapped as {"params": sd}.
        # The converter should detect that and dig in.
        sd = _synthetic_state_dict("anime")
        wrapped = {"params": sd}
        out = convert_state_dict(wrapped, "anime")
        assert len(out) == len(sd)
        assert "first_conv.weight" in out

    def test_params_ema_unwrapping(self) -> None:
        # Some variants ship with a separate EMA weight stream.
        sd = _synthetic_state_dict("anime")
        wrapped = {"params_ema": sd}
        out = convert_state_dict(wrapped, "anime")
        assert len(out) == len(sd)

    @pytest.mark.parametrize("variant", ["general", "general-wdn", "anime"])
    def test_full_state_dict_key_count(self, variant: str) -> None:
        spec = VARIANTS[variant]
        sd = _synthetic_state_dict(variant)
        out = convert_state_dict(sd, variant)
        # body.0  → first_conv (2 keys: weight + bias)
        # body.1  → first_act (1 key: weight)
        # body.2k,2k+1 → body_pairs.{k-1}.conv (2 keys) + .act (1 key) — 3 per pair
        # last conv: 2 keys
        # total = 2 + 1 + 3 * num_conv + 2 = 5 + 3 * num_conv
        expected = 5 + 3 * spec.num_conv
        assert len(out) == len(sd) == expected, (
            f"variant={variant}: got {len(out)} MLX keys vs {len(sd)} PT keys "
            f"vs expected {expected}"
        )

    def test_dtype_float16(self) -> None:
        sd = {"body.0.weight": np.ones((4, 3, 3, 3), dtype=np.float32)}
        out = convert_state_dict(sd, "anime", dtype="float16")
        assert out["first_conv.weight"].dtype == mx.float16

    def test_dtype_float32(self) -> None:
        sd = {"body.0.weight": np.ones((4, 3, 3, 3), dtype=np.float32)}
        out = convert_state_dict(sd, "anime", dtype="float32")
        assert out["first_conv.weight"].dtype == mx.float32

    def test_dtype_rejects_unknown(self) -> None:
        with pytest.raises(ValueError):
            convert_state_dict({}, "anime", dtype="float64")

    def test_unknown_variant_rejected(self) -> None:
        with pytest.raises(ValueError):
            convert_state_dict({}, "swinir-tiny")

    def test_rejects_unsupported_value_type(self) -> None:
        with pytest.raises(TypeError):
            convert_state_dict({"body.0.weight": "nope"}, "anime")  # type: ignore[arg-type]

    @pytest.mark.parametrize("variant", ["general", "general-wdn", "anime"])
    def test_all_outputs_are_mx_arrays(self, variant: str) -> None:
        sd = _synthetic_state_dict(variant)
        out = convert_state_dict(sd, variant)
        for k, v in out.items():
            assert isinstance(v, mx.array), f"{k}: got {type(v).__name__}"


# ----------------------------------------------------------------------------
# Save / round-trip + load into MLX-Python model
# ----------------------------------------------------------------------------

class TestRoundTrip:

    @pytest.mark.parametrize("variant", ["general", "general-wdn", "anime"])
    def test_save_then_load_recovers_identical_keys(
        self, tmp_path: Path, variant: str,
    ) -> None:
        sd = _synthetic_state_dict(variant)
        mlx_state = convert_state_dict(sd, variant)
        out = tmp_path / f"{variant}.safetensors"
        save_mlx_weights(mlx_state, out)
        reread = mx.load(str(out))
        assert set(reread.keys()) == set(mlx_state.keys())

    @pytest.mark.parametrize("variant", ["general", "general-wdn", "anime"])
    def test_save_then_load_recovers_values(
        self, tmp_path: Path, variant: str,
    ) -> None:
        sd = _synthetic_state_dict(variant)
        mlx_state = convert_state_dict(sd, variant)
        out = tmp_path / f"{variant}.safetensors"
        save_mlx_weights(mlx_state, out)
        reread = mx.load(str(out))
        for k in mlx_state:
            a = np.array(mlx_state[k])
            b = np.array(reread[k])
            assert a.shape == b.shape
            assert a.dtype == b.dtype
            np.testing.assert_array_equal(a, b)

    @pytest.mark.parametrize("variant", ["general", "general-wdn", "anime"])
    def test_saved_file_loads_into_mlx_python_model(
        self, tmp_path: Path, variant: str,
    ) -> None:
        """Smoke-test the deliverable: the converted file loads into the MLX
        reference model with no unused keys (proxy for Swift's
        ``update(verify: .noUnusedKeys)`` runtime check).
        """
        from Python.models.srvggnet_mlx import SRVGGNetCompact

        spec = VARIANTS[variant]
        sd = _synthetic_state_dict(variant)
        mlx_state = convert_state_dict(sd, variant)
        out = tmp_path / f"{variant}_load.safetensors"
        save_mlx_weights(mlx_state, out)

        model = SRVGGNetCompact(
            num_in_ch=3, num_out_ch=3,
            num_feat=spec.num_feat, num_conv=spec.num_conv,
            upscale=spec.upscale, act_type=spec.act_type,
        )
        loaded = mx.load(str(out))
        model.load_weights(list(loaded.items()))

        # Verify the model's flat key set exactly matches the loaded file.
        from mlx.utils import tree_flatten
        model_keys = {k for k, _ in tree_flatten(model.parameters())}
        file_keys = set(loaded.keys())
        assert model_keys == file_keys, (
            f"\nvariant={variant}\n"
            f"model-only keys: {sorted(model_keys - file_keys)}\n"
            f"file-only keys:  {sorted(file_keys - model_keys)}"
        )

    @pytest.mark.parametrize("variant", ["general", "general-wdn", "anime"])
    def test_forward_pass_runs_after_load(
        self, tmp_path: Path, variant: str,
    ) -> None:
        from Python.models.srvggnet_mlx import SRVGGNetCompact

        spec = VARIANTS[variant]
        sd = _synthetic_state_dict(variant)
        mlx_state = convert_state_dict(sd, variant)
        out = tmp_path / f"{variant}_fwd.safetensors"
        save_mlx_weights(mlx_state, out)

        model = SRVGGNetCompact(
            num_in_ch=3, num_out_ch=3,
            num_feat=spec.num_feat, num_conv=spec.num_conv,
            upscale=spec.upscale, act_type=spec.act_type,
        )
        loaded = mx.load(str(out))
        model.load_weights(list(loaded.items()))

        x = mx.zeros((1, 16, 16, 3))
        y = model(x)
        mx.eval(y)
        assert y.shape == (1, 16 * spec.upscale, 16 * spec.upscale, 3)


# ----------------------------------------------------------------------------
# CLI smoke
# ----------------------------------------------------------------------------

class TestMainCLI:

    @pytest.mark.parametrize("variant", ["general", "general-wdn", "anime"])
    def test_main_end_to_end_on_synthetic_checkpoint(
        self, tmp_path: Path, variant: str,
    ) -> None:
        """Exercise ``main()`` on a synthetic .pth without touching the network."""
        torch = pytest.importorskip("torch", exc_type=ImportError)

        sd = _synthetic_state_dict(variant)
        pt_sd = {k: torch.from_numpy(v) for k, v in sd.items()}
        # Upstream wraps under "params" — replicate to test the unwrap path.
        wrapped = {"params": pt_sd}
        pt_path = tmp_path / "synthetic.pth"
        torch.save(wrapped, pt_path)

        out_path = tmp_path / "synthetic.safetensors"

        from Scripts.convert_srvggnet_to_mlx import main
        rc = main([
            "--variant", variant,
            "--input", str(pt_path),
            "--output", str(out_path),
            "--dtype", "float32",
        ])
        assert rc == 0
        assert out_path.exists()

        spec = VARIANTS[variant]
        reread = mx.load(str(out_path))
        assert len(reread) == 5 + 3 * spec.num_conv
