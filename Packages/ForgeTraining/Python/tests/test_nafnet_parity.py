"""PyTorch ↔ MLX numerical parity for the NAFNet B.4 conversion (Task #13).

Builds a NAFNet with all params randomized (so every path — including the
beta/gamma residual scales that are zero-init in a fresh model — is exercised),
converts its state_dict, loads it into the MLX reference, and compares a forward
pass. Requires torch (skipped otherwise).

Thresholds (mlx-porting skill): fp32 single full pass < 1e-3 (ideal),
fp16 storage drift < 1e-2.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest
import mlx.core as mx

torch = pytest.importorskip("torch")

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent.parent.parent))  # Packages/ForgeTraining/

from Python.models.nafnet_torch import NAFNet as PTNAFNet  # noqa: E402
from Python.models.nafnet_mlx import NAFNet as MLXNAFNet  # noqa: E402
from Scripts.convert_nafnet_to_mlx import convert_state_dict, save_mlx_weights  # noqa: E402


def _randomized_pt(width: int = 24, seed: int = 0) -> "torch.nn.Module":
    torch.manual_seed(seed)
    m = PTNAFNet(width=width)
    with torch.no_grad():
        for p in m.parameters():
            p.copy_(torch.randn_like(p) * 0.1)
    m.eval()
    return m


def _run_parity(width: int, dtype: str, shape, tmp_path, seed=7) -> float:
    pt = _randomized_pt(width=width)
    mlx_state = convert_state_dict(pt.state_dict(), dtype=dtype)
    path = tmp_path / f"nafnet_{dtype}.safetensors"
    save_mlx_weights(mlx_state, path)

    m = MLXNAFNet(width=width)
    m.load_weights(list(mx.load(str(path)).items()))  # strict — key set must match
    m.eval()

    rng = np.random.default_rng(seed)
    x = rng.standard_normal(shape, dtype=np.float32)  # NCHW
    with torch.no_grad():
        y_pt = pt(torch.from_numpy(x)).numpy()
    y_mlx = m(mx.array(np.transpose(x, (0, 2, 3, 1))))
    mx.eval(y_mlx)
    y_mlx_nchw = np.transpose(np.array(y_mlx), (0, 3, 1, 2))
    assert y_pt.shape == y_mlx_nchw.shape == shape
    return float(np.abs(y_pt - y_mlx_nchw).max())


def test_parity_fp32(tmp_path):
    max_abs = _run_parity(24, "float32", (1, 3, 64, 64), tmp_path)
    assert max_abs < 1e-3, f"fp32 parity max_abs={max_abs:.3e}"


def test_parity_fp16(tmp_path):
    # fp32 (test_parity_fp32) is the port-correctness gate at <1e-3 (~2e-6 in
    # practice). This test only guards that fp16 *storage* rounding doesn't blow
    # up into port-bug territory. Note: random weights (×0.1) are a harsher
    # condition than a trained model — they drift to ~3e-2 here, whereas the
    # real trained checkpoint measures ~6.8e-4 fp16 via the conversion CLI. So
    # the bound is the skill's port-bug boundary (1e-1), not the trained 1e-2.
    max_abs = _run_parity(24, "float16", (1, 3, 64, 64), tmp_path)
    assert max_abs < 1e-1, f"fp16 parity max_abs={max_abs:.3e} (port bug if >1e-1)"


def test_parity_nonsquare_padding(tmp_path):
    # 56×72 are not multiples of 16 → exercises pad + crop on both sides.
    max_abs = _run_parity(24, "float32", (1, 3, 56, 72), tmp_path)
    assert max_abs < 1e-3, f"non-square parity max_abs={max_abs:.3e}"
