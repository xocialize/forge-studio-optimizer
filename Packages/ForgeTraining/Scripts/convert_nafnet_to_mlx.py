"""convert_nafnet_to_mlx.py — PyTorch → MLX safetensors converter for NAFNet.

Phase B.4 / Task #13. Reads a NAFNet checkpoint trained by ``train_nafnet.py``
(``nafnet_best.pt`` or any ``ckpt_*.pt`` — both wrap the state_dict under
``"model"``) and writes an MLX-compatible safetensors whose keys match the
Swift ``ForgeOptimizer.NAFNet`` ``@ModuleInfo`` flatten.

Key remap (PyTorch ``nafnet_torch`` → Swift/MLX ``NAFNet.swift``)
----------------------------------------------------------------
    encoders.<i>.<j>.*   → encoders.<i>.blocks.layers.<j>.*
    downs.<i>.*          → encoders.<i>.down.*
    ups.<i>.0.*          → decoders.<i>.upConv.*
    decoders.<i>.<j>.*   → decoders.<i>.blocks.layers.<j>.*
    middle_blks.<j>.*    → middle_blks.layers.<j>.*
    norm{1,2}.{w,b}      → norm{1,2}.norm.{w,b}    (Swift wraps LayerNorm as .norm)
    intro / ending       → unchanged

Layout
------
    Conv2d weight (incl. 3×3 depthwise (dw,1,3,3)):
        PyTorch (O, I/groups, kH, kW) → MLX (O, kH, kW, I/groups)   transpose(0,2,3,1)
    beta / gamma:
        PyTorch (1, C, 1, 1) → MLX NHWC (1, 1, 1, C)                transpose(0,2,3,1)
    LayerNorm weight/bias, conv bias (1-D): pass through.

Every tensor is ``mx.eval``'d before save (MLX is lazy — un-eval'd arrays
serialize as zeros silently; see the mlx-porting skill).

Usage
-----
    python Scripts/convert_nafnet_to_mlx.py \\
        --input runs/nafnet-b3/nafnet_best.pt \\
        --output ../ForgeOptimizer/Sources/ForgeOptimizer/Resources/nafnet.safetensors \\
        --dtype float16 --verify-parity
"""

from __future__ import annotations

import argparse
import logging
import re
import sys
from pathlib import Path
from typing import Any, Optional

import numpy as np
import mlx.core as mx
from safetensors.numpy import save_file as save_safetensors_numpy

_LOG = logging.getLogger("convert_nafnet_to_mlx")

# ADR-0003 default; the converter is config-agnostic but this is the expected
# count for the shipped model (sanity check, not a hard gate).
EXPECTED_PARAM_COUNT_DEFAULT = 2_541_000  # ~2.54M, ±, for width=24 [1,1,1,1] m=1


# ----------------------------------------------------------------------------
# Key remap
# ----------------------------------------------------------------------------

def _rename_block_internal(suffix: str) -> str:
    """norm1.weight → norm1.norm.weight (Swift wraps LayerNorm as a submodule)."""
    m = re.match(r"^(norm[12])\.(weight|bias)$", suffix)
    if m:
        return f"{m.group(1)}.norm.{m.group(2)}"
    return suffix


def remap_key(k: str) -> str:
    """Translate a PyTorch ``nafnet_torch`` key to the Swift ``NAFNet`` key."""
    if k.startswith("intro.") or k.startswith("ending."):
        return k

    m = re.match(r"^downs\.(\d+)\.(.+)$", k)
    if m:
        return f"encoders.{m.group(1)}.down.{m.group(2)}"

    m = re.match(r"^ups\.(\d+)\.0\.(.+)$", k)
    if m:
        return f"decoders.{m.group(1)}.upConv.{m.group(2)}"

    m = re.match(r"^encoders\.(\d+)\.(\d+)\.(.+)$", k)
    if m:
        return (f"encoders.{m.group(1)}.blocks.layers.{m.group(2)}."
                f"{_rename_block_internal(m.group(3))}")

    m = re.match(r"^decoders\.(\d+)\.(\d+)\.(.+)$", k)
    if m:
        return (f"decoders.{m.group(1)}.blocks.layers.{m.group(2)}."
                f"{_rename_block_internal(m.group(3))}")

    m = re.match(r"^middle_blks\.(\d+)\.(.+)$", k)
    if m:
        return f"middle_blks.layers.{m.group(1)}.{_rename_block_internal(m.group(2))}"

    raise KeyError(f"unmapped NAFNet key: {k!r}")


# ----------------------------------------------------------------------------
# State-dict conversion
# ----------------------------------------------------------------------------

def _to_numpy(t: Any) -> np.ndarray:
    if hasattr(t, "detach") and hasattr(t, "cpu"):
        return t.detach().cpu().numpy()
    if isinstance(t, np.ndarray):
        return t
    raise TypeError(f"expected torch.Tensor or np.ndarray, got {type(t).__name__}")


def convert_state_dict(
    pt_state_dict: dict[str, Any],
    *,
    dtype: str = "float16",
) -> dict[str, mx.array]:
    """Key-remap + layout-transpose + dtype → MLX dict (all ``mx.eval``'d)."""
    if dtype not in ("float32", "float16"):
        raise ValueError(f"dtype must be float32 or float16, got {dtype!r}")
    np_dtype = np.float16 if dtype == "float16" else np.float32

    out: dict[str, mx.array] = {}
    for key, tensor in pt_state_dict.items():
        arr = _to_numpy(tensor)
        nd = arr.ndim

        if key.endswith(".weight") and nd == 4:
            # Conv2d (standard, 1×1, and 3×3 depthwise (dw,1,3,3)).
            arr = np.transpose(arr, (0, 2, 3, 1))
        elif (key.endswith("beta") or key.endswith("gamma")) and nd == 4:
            # Per-channel residual scale (1,C,1,1) → NHWC (1,1,1,C).
            arr = np.transpose(arr, (0, 2, 3, 1))
        # 1-D (LayerNorm weight/bias, conv bias) pass through.

        arr = arr.astype(np_dtype, copy=False)
        mx_arr = mx.array(arr)
        mx.eval(mx_arr)  # materialize — lazy MLX would serialize zeros otherwise
        out[remap_key(key)] = mx_arr

    return out


def save_mlx_weights(weights: dict[str, mx.array], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    mx.eval(list(weights.values()))
    np_state = {k: np.array(v) for k, v in weights.items()}
    save_safetensors_numpy(np_state, str(output_path))
    _LOG.info("wrote %d arrays to %s (%d bytes)",
              len(np_state), output_path, output_path.stat().st_size)


# ----------------------------------------------------------------------------
# Checkpoint load
# ----------------------------------------------------------------------------

def load_pt_state_dict(path: Path) -> tuple[dict[str, Any], Optional[int]]:
    """Return (state_dict, width). Handles nafnet_best.pt and ckpt_*.pt."""
    import torch
    try:
        obj = torch.load(path, map_location="cpu", weights_only=True)
    except Exception:
        obj = torch.load(path, map_location="cpu", weights_only=False)

    width = None
    if isinstance(obj, dict) and "model" in obj and isinstance(obj["model"], dict):
        width = obj.get("width")
        obj = obj["model"]
    # else: assume obj is already a raw state_dict
    return obj, width


# ----------------------------------------------------------------------------
# Parity (PyTorch nafnet_torch ↔ MLX nafnet_mlx)
# ----------------------------------------------------------------------------

def verify_parity(
    pt_state_dict: dict[str, Any],
    mlx_safetensors: Path,
    *,
    width: int = 24,
    input_shape: tuple[int, int, int, int] = (1, 3, 64, 64),
    seed: int = 1234,
) -> tuple[float, float]:
    """Run a seeded input through PyTorch + MLX; return (max_abs, mean_abs)."""
    import torch
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # ForgeTraining/
    from Python.models.nafnet_torch import NAFNet as PTNAFNet
    from Python.models.nafnet_mlx import NAFNet as MLXNAFNet

    pt = PTNAFNet(width=width)
    pt.load_state_dict(pt_state_dict, strict=True)
    pt.eval()

    mlx_model = MLXNAFNet(width=width)
    mlx_weights = mx.load(str(mlx_safetensors))
    mlx_model.load_weights(list(mlx_weights.items()))
    mlx_model.eval()

    rng = np.random.default_rng(seed)
    n, c, h, w = input_shape
    x_nchw = rng.standard_normal((n, c, h, w), dtype=np.float32)
    x_nhwc = np.transpose(x_nchw, (0, 2, 3, 1))

    with torch.no_grad():
        y_pt = pt(torch.from_numpy(x_nchw)).cpu().numpy()  # NCHW

    y_mlx = mlx_model(mx.array(x_nhwc))
    mx.eval(y_mlx)
    y_mlx_nchw = np.transpose(np.array(y_mlx), (0, 3, 1, 2))

    diff = np.abs(y_pt.astype(np.float32) - y_mlx_nchw.astype(np.float32))
    return float(diff.max()), float(diff.mean())


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def _parse_shape(s: str) -> tuple[int, int, int, int]:
    parts = tuple(int(x) for x in s.split(","))
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(f"need N,C,H,W; got {s!r}")
    return parts  # type: ignore[return-value]


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description="Convert NAFNet PyTorch → MLX safetensors.")
    p.add_argument("--input", "-i", type=Path, required=True,
                   help="nafnet_best.pt or ckpt_*.pt")
    p.add_argument("--output", "-o", type=Path, required=True)
    p.add_argument("--dtype", choices=("float32", "float16"), default="float16")
    p.add_argument("--width", type=int, default=None,
                   help="override width if not stored in the checkpoint (default 24).")
    p.add_argument("--verify-parity", action="store_true")
    p.add_argument("--input-shape", type=_parse_shape, default=(1, 3, 64, 64))
    p.add_argument("--log-level", default="INFO",
                   choices=("DEBUG", "INFO", "WARNING", "ERROR"))
    args = p.parse_args(argv)
    logging.basicConfig(level=getattr(logging, args.log_level),
                        format="%(asctime)s %(levelname)-7s %(name)s | %(message)s")

    if not args.input.exists():
        _LOG.error("input not found: %s", args.input)
        return 2

    state_dict, width_ck = load_pt_state_dict(args.input)
    width = args.width or width_ck or 24
    n_params = sum(int(np.prod(v.shape)) for v in state_dict.values())
    _LOG.info("loaded %d tensors, %d params, width=%d", len(state_dict), n_params, width)

    mlx_state = convert_state_dict(state_dict, dtype=args.dtype)
    _LOG.info("converted → %d MLX keys", len(mlx_state))
    save_mlx_weights(mlx_state, args.output)

    reloaded = mx.load(str(args.output))
    if set(reloaded.keys()) != set(mlx_state.keys()):
        _LOG.error("round-trip key-set mismatch")
        return 4
    _LOG.info("round-trip OK: %d keys", len(reloaded))

    if args.verify_parity:
        max_abs, mean_abs = verify_parity(
            state_dict, args.output, width=width, input_shape=args.input_shape)
        _LOG.info("parity max_abs=%.4e mean_abs=%.4e", max_abs, mean_abs)
        if max_abs > 1e-1:
            _LOG.error("parity FAILED: max_abs > 1e-1 → port bug")
            return 5
        if max_abs > 1e-2:
            _LOG.warning("parity max_abs > 1e-2 (ok if --dtype float16 storage drift)")
        else:
            _LOG.info("parity within target (<1e-2)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
