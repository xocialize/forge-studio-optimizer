"""
PyTorch ↔ MLX numerical parity tests for the EfRLFN converter.

These tests require the ``parity`` extra to be installed (currently just
``torch``). Pytest's ``importorskip`` causes the whole module to be skipped if
torch is missing, so CI without the extra still passes.

Targets (per Forge-CodingPlan-v1.0.md §C.3):
    - Single-layer max_abs < 1e-3 at fp32
    - Full forward pass max_abs < 1e-2 at fp32
    - >1e-1 indicates a port bug, not numerical drift

Two test paths:

1. **Synthetic weights**: deterministic randomly-initialized state dict
   converted by ``convert_state_dict``; both backends loaded; per-layer probe
   shows where any divergence first appears. Always runs (only needs torch).

2. **Upstream weights**: real EfRLFN x4 / x2 checkpoint from upstream Google
   Drive, if present in ``$EFRLFN_CHECKPOINT_DIR``. Skipped if not available.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np
import pytest

import mlx.core as mx

torch = pytest.importorskip(
    "torch",
    reason="install the parity extra: pip install -e \".[parity]\"",
    exc_type=ImportError,
)

# Importable bootstrap.
HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent.parent.parent))  # Packages/ForgeTraining/

from Scripts.convert_efrlfn_to_mlx import (  # noqa: E402
    _build_pytorch_reference,
    convert_state_dict,
    save_mlx_weights,
)
from Python.models.efrlfn_mlx import EfRLFN as MX_EfRLFN  # noqa: E402


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

SINGLE_LAYER_MAX = 1e-3
FULL_PASS_MAX = 1e-2
PORT_BUG_THRESHOLD = 1e-1


def _seeded_input(shape: tuple[int, int, int, int], seed: int = 1234):
    """Generate identical input for both backends from a NumPy seed."""
    rng = np.random.default_rng(seed)
    x_nchw = rng.standard_normal(shape, dtype=np.float32)
    x_nhwc = np.transpose(x_nchw, (0, 2, 3, 1))
    return x_nchw, x_nhwc


def _diff_nchw_vs_nhwc(pt_arr_nchw, mx_arr_nhwc) -> float:
    pt = pt_arr_nchw.detach().cpu().numpy() if hasattr(pt_arr_nchw, "detach") else pt_arr_nchw
    mxn = np.array(mx_arr_nhwc)
    mx_nchw = np.transpose(mxn, (0, 3, 1, 2))
    return float(np.abs(pt.astype(np.float32) - mx_nchw.astype(np.float32)).max())


def _build_synthetic_pair(seed: int, scale: int):
    """Build a paired (PyTorch, MLX) model with identical random weights."""
    # 1. Construct PyTorch model with default random init at the seed.
    torch.manual_seed(seed)
    pt = _build_pytorch_reference(scale=scale)
    pt.eval()

    # 2. Convert its state_dict via the converter, save + load into MLX.
    state_dict = pt.state_dict()
    mlx_weights = convert_state_dict(state_dict)

    mx_model = MX_EfRLFN(scale=scale)
    mx_model.load_weights(list(mlx_weights.items()))
    mx_model.eval()
    return pt, mx_model


# ----------------------------------------------------------------------------
# Synthetic-weights parity (always runs when torch is present)
# ----------------------------------------------------------------------------

class TestSyntheticParity:

    def test_conv_1_single_layer(self) -> None:
        pt, mxm = _build_synthetic_pair(seed=42, scale=4)
        x_nchw, x_nhwc = _seeded_input((1, 3, 16, 16))
        with torch.no_grad():
            y_pt = pt.conv_1(torch.from_numpy(x_nchw))
        y_mx = mxm.conv_1(mx.array(x_nhwc))
        mx.eval(y_mx)
        diff = _diff_nchw_vs_nhwc(y_pt, y_mx)
        assert diff < SINGLE_LAYER_MAX, (
            f"conv_1 single-layer parity {diff:.4e} >= {SINGLE_LAYER_MAX:.0e}"
        )

    def test_eca_block_standalone(self) -> None:
        pt, mxm = _build_synthetic_pair(seed=43, scale=4)
        x_nchw, x_nhwc = _seeded_input((1, 52, 8, 8))
        with torch.no_grad():
            y_pt = pt.block_1.eca(torch.from_numpy(x_nchw))
        y_mx = mxm.block_1.eca(mx.array(x_nhwc))
        mx.eval(y_mx)
        diff = _diff_nchw_vs_nhwc(y_pt, y_mx)
        assert diff < SINGLE_LAYER_MAX, (
            f"ECA single-layer parity {diff:.4e} >= {SINGLE_LAYER_MAX:.0e}"
        )

    def test_erlfb_block_full(self) -> None:
        pt, mxm = _build_synthetic_pair(seed=44, scale=4)
        x_nchw, x_nhwc = _seeded_input((1, 52, 8, 8))
        with torch.no_grad():
            y_pt = pt.block_3(torch.from_numpy(x_nchw))
        y_mx = mxm.block_3(mx.array(x_nhwc))
        mx.eval(y_mx)
        diff = _diff_nchw_vs_nhwc(y_pt, y_mx)
        assert diff < SINGLE_LAYER_MAX, (
            f"ERLFB block parity {diff:.4e} >= {SINGLE_LAYER_MAX:.0e}"
        )

    def test_upsampler_pixel_shuffle(self) -> None:
        """Pixel-shuffle parity. This is the test that catches the
        ``(C, r, r)`` vs ``(r, r, C)`` channel-reshape bug that ADR-0006
        Task #18 follow-up was raised for.
        """
        pt, mxm = _build_synthetic_pair(seed=45, scale=4)
        # Feed the upsampler's conv input shape.
        x_nchw, x_nhwc = _seeded_input((1, 52, 8, 8))
        with torch.no_grad():
            y_pt = pt.upsampler(torch.from_numpy(x_nchw))
        y_mx = mxm.upsampler(mx.array(x_nhwc))
        mx.eval(y_mx)
        diff = _diff_nchw_vs_nhwc(y_pt, y_mx)
        assert diff < SINGLE_LAYER_MAX, (
            f"upsampler (pixel-shuffle) parity {diff:.4e} >= "
            f"{SINGLE_LAYER_MAX:.0e}. If this fails near the 2.0 range, the "
            "MLX pixel shuffle is using (r, r, C) channel ordering instead "
            "of (C, r, r) — see efrlfn_mlx._pixel_shuffle_nhwc."
        )

    def test_full_forward_scale_4(self) -> None:
        pt, mxm = _build_synthetic_pair(seed=46, scale=4)
        x_nchw, x_nhwc = _seeded_input((1, 3, 32, 32))
        with torch.no_grad():
            y_pt = pt(torch.from_numpy(x_nchw))
        y_mx = mxm(mx.array(x_nhwc))
        mx.eval(y_mx)
        diff = _diff_nchw_vs_nhwc(y_pt, y_mx)
        assert diff < FULL_PASS_MAX, (
            f"Full-pass parity {diff:.4e} >= {FULL_PASS_MAX:.0e}"
        )

    def test_full_forward_scale_2(self) -> None:
        pt, mxm = _build_synthetic_pair(seed=47, scale=2)
        x_nchw, x_nhwc = _seeded_input((1, 3, 32, 32))
        with torch.no_grad():
            y_pt = pt(torch.from_numpy(x_nchw))
        y_mx = mxm(mx.array(x_nhwc))
        mx.eval(y_mx)
        diff = _diff_nchw_vs_nhwc(y_pt, y_mx)
        assert diff < FULL_PASS_MAX, (
            f"Full-pass scale=2 parity {diff:.4e} >= {FULL_PASS_MAX:.0e}"
        )


# ----------------------------------------------------------------------------
# Upstream-checkpoint parity (skipped unless EFRLFN_CHECKPOINT_DIR is set)
# ----------------------------------------------------------------------------

def _upstream_checkpoint(scale: int) -> Path | None:
    """Return the upstream checkpoint path if findable, else None.

    Looks at ``$EFRLFN_CHECKPOINT_DIR/efrlfn_x{scale}.pt`` first, then at the
    converter's default cache dir.
    """
    candidates: list[Path] = []
    env = os.environ.get("EFRLFN_CHECKPOINT_DIR")
    if env:
        candidates.append(Path(env) / f"efrlfn_x{scale}.pt")
    candidates.append(Path.home() / ".cache" / "efrlfn_weights" / f"efrlfn_x{scale}.pt")
    # Allow tests to opt in via /tmp.
    candidates.append(Path("/tmp/efrlfn_weights") / f"efrlfn_x{scale}.pt")
    for p in candidates:
        if p.exists():
            return p
    return None


@pytest.mark.skipif(
    _upstream_checkpoint(4) is None,
    reason="upstream x4 checkpoint not present; set EFRLFN_CHECKPOINT_DIR",
)
class TestUpstreamParityScale4:

    def test_full_pass_under_threshold(self, tmp_path: Path) -> None:
        from Scripts.convert_efrlfn_to_mlx import verify_parity
        ckpt = _upstream_checkpoint(4)
        assert ckpt is not None

        state_dict = torch.load(ckpt, map_location="cpu", weights_only=True)
        mlx_state = convert_state_dict(state_dict)
        out = tmp_path / "efrlfn_x4.safetensors"
        save_mlx_weights(mlx_state, out)

        report = verify_parity(ckpt, out, scale=4, input_shape=(1, 3, 32, 32))
        assert report.max_abs < FULL_PASS_MAX, (
            f"upstream x4 parity {report.max_abs:.4e} >= {FULL_PASS_MAX:.0e}\n"
            f"notes: {report.notes}"
        )


@pytest.mark.skipif(
    _upstream_checkpoint(2) is None,
    reason="upstream x2 checkpoint not present; set EFRLFN_CHECKPOINT_DIR",
)
class TestUpstreamParityScale2:

    def test_full_pass_under_threshold(self, tmp_path: Path) -> None:
        from Scripts.convert_efrlfn_to_mlx import verify_parity
        ckpt = _upstream_checkpoint(2)
        assert ckpt is not None

        state_dict = torch.load(ckpt, map_location="cpu", weights_only=True)
        mlx_state = convert_state_dict(state_dict)
        out = tmp_path / "efrlfn_x2.safetensors"
        save_mlx_weights(mlx_state, out)

        report = verify_parity(ckpt, out, scale=2, input_shape=(1, 3, 32, 32))
        assert report.max_abs < FULL_PASS_MAX, (
            f"upstream x2 parity {report.max_abs:.4e} >= {FULL_PASS_MAX:.0e}\n"
            f"notes: {report.notes}"
        )
