"""
convert_efrlfn_to_mlx.py — PyTorch → MLX safetensors converter for EfRLFN.

Per Forge-CodingPlan-v1.0.md Phase C.3 + ADR-0006.

Reads the upstream EfRLFN PyTorch checkpoint (downloadable from the official
repo's Google Drive — see ``download_checkpoint``) and writes an MLX-compatible
safetensors file with key names matching the Swift ``ForgeUpscaler.EfRLFN``
module's ``@ModuleInfo`` flatten.

Key conventions
---------------

- Conv2d weights: PyTorch ``(O, I, kH, kW)`` → MLX ``(O, kH, kW, I)``
- Conv1d weights: PyTorch ``(O, I, k)``      → MLX ``(O, k, I)``
- Every weight materialized with ``mx.eval(...)`` before save (MLX is lazy;
  un-eval'd tensors serialize as zeros with no error — see mlx-porting skill).
- Upstream uses ``nn.Sequential`` for the upsampler so PyTorch keys are
  ``upsampler.0.{weight,bias}``. The Swift port wraps the (conv, PixelShuffle)
  pair in a named ``PixelShuffleBlock`` whose conv is bound to ``upsampler.conv``.
  We remap on the fly.
- All other names pass through unchanged — upstream and Swift port already
  share the ``conv_1`` / ``conv_2`` / ``block_1..block_6`` / ECA naming.

Usage
-----

    # Convert + verify the safetensors round-trips via mx.load_safetensors:
    python convert_efrlfn_to_mlx.py \\
        --input ~/Downloads/efrlfn_x4.pt \\
        --output ../ForgeUpscaler/Sources/ForgeUpscaler/Resources/efrlfn_x4.safetensors \\
        --scale 4

    # With parity test against the upstream PyTorch reference (needs torch):
    python convert_efrlfn_to_mlx.py \\
        --input ~/Downloads/efrlfn_x4.pt \\
        --output efrlfn_x4.safetensors \\
        --scale 4 \\
        --verify-parity \\
        --input-shape 1,3,64,64

    # Auto-download from upstream Google Drive (saves to --cache-dir):
    python convert_efrlfn_to_mlx.py \\
        --scale 4 \\
        --output efrlfn_x4.safetensors \\
        --cache-dir /tmp/efrlfn_weights

Plan ref
--------
- Docs/Forge-CodingPlan-v1.0.md §C.3 (Task #20)
- Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md §"Verified at port"
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Optional

import numpy as np

import mlx.core as mx

# `safetensors.numpy` (writer) and `mlx.core.load` (reader). We use the
# safetensors writer rather than `mx.save_safetensors` because the latter is a
# thin wrapper and the numpy writer is more explicit about dtype + key order.
from safetensors.numpy import save_file as save_safetensors_numpy

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

_LOG = logging.getLogger("convert_efrlfn_to_mlx")


# ----------------------------------------------------------------------------
# Upstream Google Drive file IDs (from
# https://github.com/EvgeneyBogatyrev/EfRLFN README §"Model Weights").
# ----------------------------------------------------------------------------

UPSTREAM_GDRIVE_IDS: dict[int, str] = {
    2: "1VeoW94hN1X-8kxGXQSyR53YzRqF1htKQ",
    4: "1vJgrsz62IAMeS9i2ChDhQGO6UO1ZUXhr",
}

# Verified at convert time (2026-05-27). Pinned for reproducibility — if these
# drift, the upstream checkpoint moved and the script should refuse to proceed
# silently.
UPSTREAM_SHA256: dict[int, str] = {
    2: "fbfd1bb37973d2b8b53493c5b91c0ef106f74d200115250a8a025b8e6a121cb3",
    4: "56a43a1071c447083f236a91e145b909d1a33beaeb0fc6ddf9f1c88b71620e1c",
}

# Param-count precondition (matches ADR-0006 §"Verified at port" for scale=4).
EXPECTED_PARAM_COUNT: dict[int, int] = {
    2: 487_010,
    4: 503_894,
}


# ----------------------------------------------------------------------------
# Config dataclass
# ----------------------------------------------------------------------------

@dataclass
class ConverterConfig:
    """Conversion + parity-check options."""

    input_path: Optional[Path]
    output_path: Path
    scale: int
    cache_dir: Optional[Path]
    verify_parity: bool
    input_shape: tuple[int, int, int, int]
    dtype: str  # "float32" or "float16"

    def __post_init__(self) -> None:
        if self.scale not in UPSTREAM_GDRIVE_IDS:
            raise ValueError(
                f"unsupported scale {self.scale}; upstream publishes "
                f"{sorted(UPSTREAM_GDRIVE_IDS)}"
            )
        if self.dtype not in ("float32", "float16"):
            raise ValueError(f"dtype must be float32 or float16, got {self.dtype!r}")


@dataclass
class ParityReport:
    """Result of `verify_parity` — surfaced in the CLI and in tests."""

    max_abs: float
    mean_abs: float
    divergent_layer_name: Optional[str] = None
    per_layer_max_abs: dict[str, float] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)


# ----------------------------------------------------------------------------
# Checkpoint download
# ----------------------------------------------------------------------------

def download_checkpoint(scale: int, cache_dir: Path) -> Path:
    """Fetch the upstream EfRLFN PyTorch checkpoint for the given scale.

    The upstream README hosts weights on Google Drive (no HuggingFace mirror as
    of 2026-05-27). For files under ~100 MB the ``uc?export=download`` URL
    serves the binary directly without the usual virus-scan interstitial.

    Args:
        scale: 2 or 4.
        cache_dir: directory to write into. Created if missing.

    Returns:
        Path to the downloaded ``.pt`` checkpoint.

    Raises:
        RuntimeError: if the download fails or the SHA-256 does not match the
            pinned value in :data:`UPSTREAM_SHA256`.
    """
    import urllib.request

    if scale not in UPSTREAM_GDRIVE_IDS:
        raise ValueError(f"no upstream Google Drive ID for scale={scale}")

    cache_dir.mkdir(parents=True, exist_ok=True)
    dst = cache_dir / f"efrlfn_x{scale}.pt"

    if dst.exists():
        actual = _sha256_file(dst)
        if actual == UPSTREAM_SHA256[scale]:
            _LOG.info("cached checkpoint OK: %s", dst)
            return dst
        _LOG.warning(
            "cached checkpoint SHA mismatch (got %s, want %s); re-downloading",
            actual, UPSTREAM_SHA256[scale],
        )
        dst.unlink()

    file_id = UPSTREAM_GDRIVE_IDS[scale]
    url = f"https://drive.google.com/uc?export=download&id={file_id}"
    _LOG.info("downloading EfRLFN x%d weights from %s", scale, url)

    try:
        with urllib.request.urlopen(url) as resp, open(dst, "wb") as f:
            f.write(resp.read())
    except Exception as e:
        raise RuntimeError(
            f"download failed for scale={scale}: {e}. "
            f"Manual fetch: open {url} in a browser, save to {dst}."
        ) from e

    actual = _sha256_file(dst)
    if actual != UPSTREAM_SHA256[scale]:
        raise RuntimeError(
            f"SHA mismatch after download: got {actual}, want "
            f"{UPSTREAM_SHA256[scale]}. Upstream weights may have been "
            f"updated — verify and pin the new hash."
        )
    _LOG.info("downloaded + verified: %s (%d bytes)", dst, dst.stat().st_size)
    return dst


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ----------------------------------------------------------------------------
# State-dict conversion
# ----------------------------------------------------------------------------

def _is_conv2d_weight(key: str, shape: tuple[int, ...]) -> bool:
    """Heuristic: a 4-D weight in EfRLFN is a Conv2d kernel."""
    return key.endswith(".weight") and len(shape) == 4


def _is_conv1d_weight(key: str, shape: tuple[int, ...]) -> bool:
    """Heuristic: a 3-D weight in EfRLFN is the ECA Conv1d kernel."""
    return key.endswith(".weight") and len(shape) == 3


def _remap_key(pt_key: str) -> str:
    """Translate an upstream PyTorch parameter key to the Swift module's key.

    Upstream uses ``nn.Sequential`` for the pixel-shuffle block, so the conv's
    state-dict key is ``upsampler.0.weight``. The Swift port (and the
    MLX-Python reference) names that conv ``upsampler.conv`` — a named
    sub-module rather than a positional one.

    All other names already match between upstream and the Swift port:
    ``conv_1`` / ``conv_2`` / ``block_1..6.{c1_r,c2_r,c3_r,c5}`` / ``block_N.eca.conv``.
    """
    if pt_key.startswith("upsampler.0."):
        return "upsampler.conv." + pt_key[len("upsampler.0."):]
    return pt_key


def convert_state_dict(
    pt_state_dict: dict[str, Any],
    *,
    dtype: str = "float32",
) -> dict[str, mx.array]:
    """Apply the key remap + layout transpose + dtype, returning an MLX dict.

    PyTorch ``state_dict`` ships ``torch.Tensor`` instances — we read their
    NumPy view via ``.cpu().numpy()`` (the tests inject pre-built
    ``numpy.ndarray`` values directly, which also Just Works).

    Args:
        pt_state_dict: keyed by upstream parameter name; values are
            ``torch.Tensor`` (preferred) or ``numpy.ndarray`` (test path).
        dtype: ``"float32"`` (default) or ``"float16"``. Picks the on-disk
            precision; FP16 halves the vendored safetensors size (~1 MB → ~0.5 MB).

    Returns:
        Dict keyed by Swift-side parameter name, values are ``mx.array``
        instances that have been ``mx.eval``'d.
    """
    if dtype not in ("float32", "float16"):
        raise ValueError(f"dtype must be float32 or float16, got {dtype!r}")
    target_np_dtype = np.float16 if dtype == "float16" else np.float32

    out: dict[str, mx.array] = {}

    for key, tensor in pt_state_dict.items():
        # Accept torch.Tensor or numpy.ndarray transparently.
        if hasattr(tensor, "cpu") and hasattr(tensor, "numpy"):
            arr = tensor.detach().cpu().numpy()
        elif isinstance(tensor, np.ndarray):
            arr = tensor
        else:
            raise TypeError(
                f"key {key!r}: expected torch.Tensor or numpy.ndarray, "
                f"got {type(tensor).__name__}"
            )

        shape = tuple(arr.shape)

        if _is_conv2d_weight(key, shape):
            # PyTorch Conv2d weight: (O, I, kH, kW)
            # MLX Conv2d weight:     (O, kH, kW, I)
            arr = np.transpose(arr, (0, 2, 3, 1))
        elif _is_conv1d_weight(key, shape):
            # PyTorch Conv1d weight: (O, I, k)
            # MLX Conv1d weight:     (O, k, I)
            arr = np.transpose(arr, (0, 2, 1))
        # Biases (1-D) and the unlikely scalar cases pass through unchanged.

        arr = arr.astype(target_np_dtype, copy=False)

        new_key = _remap_key(key)
        mx_arr = mx.array(arr)
        # Force materialization. MLX is lazy — without this, save_safetensors
        # can serialize zeros (and even mx.eval-after-save won't help, the
        # bytes were already written). See mlx-porting skill §"silent killer".
        mx.eval(mx_arr)
        out[new_key] = mx_arr

    return out


# ----------------------------------------------------------------------------
# Save
# ----------------------------------------------------------------------------

def save_mlx_weights(
    weights: dict[str, mx.array],
    output_path: Path,
) -> None:
    """Write ``weights`` to a safetensors file readable by ``mx.load_safetensors``.

    Re-evaluates every array before write as a paranoid defense against lazy
    evaluation — :func:`convert_state_dict` already evals, but a caller could
    pass arrays produced any number of ways.
    """
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Re-eval. mx.eval accepts any iterable of arrays.
    mx.eval(list(weights.values()))

    # Convert to numpy for safetensors.numpy.save_file. We could call
    # mx.save_safetensors directly, but the explicit numpy path makes dtype
    # handling visible and is what the unit tests exercise.
    np_state: dict[str, np.ndarray] = {}
    for k, v in weights.items():
        # mx.array → numpy via __array__ (zero-copy where dtype matches host).
        np_state[k] = np.array(v)

    save_safetensors_numpy(np_state, str(output_path))
    _LOG.info("wrote %d arrays to %s (%d bytes)",
              len(np_state), output_path, output_path.stat().st_size)


# ----------------------------------------------------------------------------
# Parity check (PyTorch ↔ MLX)
# ----------------------------------------------------------------------------

def verify_parity(
    pt_checkpoint: Path,
    mlx_safetensors: Path,
    scale: int,
    input_shape: tuple[int, int, int, int] = (1, 3, 64, 64),
    seed: int = 1234,
) -> ParityReport:
    """Run a forward pass on a seeded NumPy input through both backends.

    PyTorch RNG and MLX RNG are not compatible — we build the input as a
    seeded NumPy array and inject the identical bytes into both sides.

    Args:
        pt_checkpoint: upstream ``.pt`` (loaded into a PyTorch EfRLFN ref).
        mlx_safetensors: the converted ``.safetensors``.
        scale: 2 or 4. Selects the upstream config.
        input_shape: ``(N, C, H, W)`` for PyTorch; transposed to NHWC for MLX.
        seed: NumPy seed for input generation.

    Returns:
        :class:`ParityReport`.

    Raises:
        ImportError: if PyTorch isn't installed. The caller should treat this
            as a soft skip (the unit tests use ``pytest.importorskip``).
    """
    import torch  # local — keep PyTorch out of the import path otherwise

    # Need access to the upstream model. We don't have a `pip install efrlfn`,
    # so we import our local MLX reference and a tiny inline PyTorch port that
    # exactly mirrors `code/model.py` + `code/blocks.py`. Defined here rather
    # than as a sibling module because it's only used inside parity.
    pt_model = _build_pytorch_reference(scale=scale)
    state_dict = torch.load(pt_checkpoint, map_location="cpu", weights_only=True)
    pt_model.load_state_dict(state_dict, strict=True)
    pt_model.eval()

    # MLX side — import sibling reference.
    from Python.models.efrlfn_mlx import EfRLFN as MLXEfRLFN  # noqa: E402

    mlx_model = MLXEfRLFN(scale=scale)
    mlx_weights = mx.load(str(mlx_safetensors))
    mlx_model.load_weights(list(mlx_weights.items()))
    mlx_model.eval()

    # Build identical input.
    rng = np.random.default_rng(seed)
    n, c, h, w = input_shape
    x_nchw = rng.standard_normal((n, c, h, w), dtype=np.float32)
    x_nhwc = np.transpose(x_nchw, (0, 2, 3, 1))

    # Forward.
    with torch.no_grad():
        y_pt = pt_model(torch.from_numpy(x_nchw)).cpu().numpy()  # NCHW

    y_mlx = mlx_model(mx.array(x_nhwc))
    mx.eval(y_mlx)
    y_mlx_np = np.array(y_mlx)  # NHWC
    # Convert MLX output to NCHW for comparison.
    y_mlx_nchw = np.transpose(y_mlx_np, (0, 3, 1, 2))

    diff = np.abs(y_pt.astype(np.float32) - y_mlx_nchw.astype(np.float32))
    full_max = float(diff.max())
    full_mean = float(diff.mean())

    report = ParityReport(max_abs=full_max, mean_abs=full_mean)
    if full_max > 1e-1:
        report.notes.append(
            f"full-pass max_abs={full_max:.4e} exceeds 1e-1 — likely port bug, "
            "not numerical drift. Inspect per-layer diffs."
        )
    elif full_max > 1e-2:
        report.notes.append(
            f"full-pass max_abs={full_max:.4e} exceeds 1e-2 — high but may be "
            "consistent with FP32→FP16 storage drift if --dtype=float16 was used."
        )
    else:
        report.notes.append(
            f"full-pass max_abs={full_max:.4e} within target (<1e-2)."
        )
    return report


def _build_pytorch_reference(scale: int):
    """Inline transcription of upstream ``code/model.py`` + ``code/blocks.py``.

    We re-define the architecture here rather than ``pip install`` the upstream
    repo (which uses an absolute ``import code.blocks`` that conflicts with the
    Python stdlib ``code`` module). Verbatim transposition of the upstream
    forward pass — see ADR-0006 §"Verified at port" for the six quirks honored.
    """
    import torch
    import torch.nn as nn

    def conv_layer(in_ch: int, out_ch: int, k: int, bias: bool = True) -> nn.Conv2d:
        return nn.Conv2d(in_ch, out_ch, k, padding=(k - 1) // 2, bias=bias)

    class ECABlock(nn.Module):
        def __init__(self, k_size: int = 3) -> None:
            super().__init__()
            self.avg_pool = nn.AdaptiveAvgPool2d(1)
            self.conv = nn.Conv1d(1, 1, kernel_size=k_size,
                                  padding=(k_size - 1) // 2, bias=False)
            self.sigmoid = nn.Sigmoid()

        def forward(self, x: torch.Tensor) -> torch.Tensor:
            y = self.avg_pool(x).squeeze(-1).permute(0, 2, 1)
            y = self.conv(y).permute(0, 2, 1).unsqueeze(-1)
            y = self.sigmoid(y)
            return x * y

    class ERLFB(nn.Module):
        def __init__(self, ch: int) -> None:
            super().__init__()
            self.c1_r = conv_layer(ch, ch, 3)
            self.c2_r = conv_layer(ch, ch, 3)
            self.c3_r = conv_layer(ch, ch, 3)
            self.c5 = conv_layer(ch, ch, 1)
            self.eca = ECABlock()
            self.act = torch.tanh

        def forward(self, x: torch.Tensor) -> torch.Tensor:
            out = self.act(self.c1_r(x))
            out = self.act(self.c2_r(out))
            out = self.act(self.c3_r(out))
            out = out + x
            return self.eca(self.c5(out))

    class PixelShuffleBlock(nn.Sequential):
        # Upstream uses `sequential(conv, nn.PixelShuffle(r))` so the conv ends
        # up at key "0" in the state dict — matches the key remap below.
        def __init__(self, in_ch: int, out_ch: int, scale: int) -> None:
            super().__init__(
                conv_layer(in_ch, out_ch * scale * scale, 3),
                nn.PixelShuffle(scale),
            )

    class EfRLFN(nn.Module):
        def __init__(
            self,
            in_channels: int = 3,
            out_channels: int = 3,
            feature_channels: int = 52,
            upscale: int = 4,
        ) -> None:
            super().__init__()
            self.conv_1 = conv_layer(in_channels, feature_channels, 3)
            self.block_1 = ERLFB(feature_channels)
            self.block_2 = ERLFB(feature_channels)
            self.block_3 = ERLFB(feature_channels)
            self.block_4 = ERLFB(feature_channels)
            self.block_5 = ERLFB(feature_channels)
            self.block_6 = ERLFB(feature_channels)
            self.conv_2 = conv_layer(feature_channels, feature_channels, 3)
            self.upsampler = PixelShuffleBlock(feature_channels, out_channels, upscale)

        def forward(self, x: torch.Tensor) -> torch.Tensor:
            out_feature = self.conv_1(x)
            out = self.block_1(out_feature)
            out = self.block_2(out)
            out = self.block_3(out)
            out = self.block_4(out)
            out = self.block_5(out)
            out = self.block_6(out)
            out_lr = self.conv_2(out + out_feature)
            return self.upsampler(out_lr)

    return EfRLFN(upscale=scale)


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def _parse_input_shape(s: str) -> tuple[int, int, int, int]:
    parts = [int(x) for x in s.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(
            f"input-shape needs 4 ints (N,C,H,W); got {s!r}"
        )
    return (parts[0], parts[1], parts[2], parts[3])


def _build_argparser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Convert EfRLFN PyTorch checkpoint → MLX safetensors.",
    )
    p.add_argument(
        "--input", "-i", type=Path, default=None,
        help="path to upstream PyTorch .pt; omit to auto-download via "
             "--cache-dir.",
    )
    p.add_argument(
        "--output", "-o", type=Path, required=True,
        help="output safetensors path.",
    )
    p.add_argument(
        "--scale", "-s", type=int, choices=(2, 4), default=4,
        help="upscale factor; 2 or 4. Default: 4.",
    )
    p.add_argument(
        "--cache-dir", type=Path,
        default=Path.home() / ".cache" / "efrlfn_weights",
        help="where to cache the upstream checkpoint when auto-downloading.",
    )
    p.add_argument(
        "--dtype", choices=("float32", "float16"), default="float32",
        help="on-disk weight dtype. float16 halves bundle size (~1.0 MB → "
             "~0.5 MB) at the cost of small additional precision loss.",
    )
    p.add_argument(
        "--verify-parity", action="store_true",
        help="run a numerical-parity test against the upstream PyTorch model "
             "after conversion. Requires torch to be importable.",
    )
    p.add_argument(
        "--input-shape", type=_parse_input_shape, default=(1, 3, 64, 64),
        help="parity-test input shape as N,C,H,W. Default: 1,3,64,64.",
    )
    p.add_argument(
        "--log-level", default="INFO",
        choices=("DEBUG", "INFO", "WARNING", "ERROR"),
    )
    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = _build_argparser().parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)-7s %(name)s | %(message)s",
    )

    cfg = ConverterConfig(
        input_path=args.input,
        output_path=args.output,
        scale=args.scale,
        cache_dir=args.cache_dir,
        verify_parity=args.verify_parity,
        input_shape=args.input_shape,
        dtype=args.dtype,
    )

    # 1. Resolve checkpoint.
    if cfg.input_path is not None:
        pt_path = cfg.input_path
        if not pt_path.exists():
            _LOG.error("input checkpoint not found: %s", pt_path)
            return 2
    else:
        if cfg.cache_dir is None:
            _LOG.error("either --input or --cache-dir is required")
            return 2
        pt_path = download_checkpoint(cfg.scale, cfg.cache_dir)

    # 2. Load state dict.
    try:
        import torch
    except ImportError:
        _LOG.error(
            "torch is required to read .pt checkpoints. "
            "Install via: pip install -e \".[parity]\""
        )
        return 3
    state_dict = torch.load(pt_path, map_location="cpu", weights_only=True)
    n_params = sum(int(np.prod(v.shape)) for v in state_dict.values())
    expected = EXPECTED_PARAM_COUNT[cfg.scale]
    if n_params != expected:
        _LOG.warning(
            "param count %d does not match expected %d for scale=%d "
            "(per ADR-0006). Proceeding, but expect the Swift loader's "
            "verify=.noUnusedKeys to flag this.",
            n_params, expected, cfg.scale,
        )
    else:
        _LOG.info("param count %d matches expected for scale=%d", n_params, cfg.scale)

    # 3. Convert.
    mlx_state = convert_state_dict(state_dict, dtype=cfg.dtype)
    _LOG.info("converted %d keys (PT) → %d keys (MLX)",
              len(state_dict), len(mlx_state))

    # 4. Save.
    save_mlx_weights(mlx_state, cfg.output_path)

    # 5. Round-trip sanity: reload via mx.load and confirm key set.
    reloaded = mx.load(str(cfg.output_path))
    if set(reloaded.keys()) != set(mlx_state.keys()):
        _LOG.error(
            "round-trip key-set mismatch: written=%d, reread=%d",
            len(mlx_state), len(reloaded),
        )
        return 4
    _LOG.info("round-trip OK: %d keys recoverable from %s",
              len(reloaded), cfg.output_path)

    # 6. Optional parity.
    if cfg.verify_parity:
        _LOG.info("running parity vs PyTorch reference at shape=%s",
                  cfg.input_shape)
        report = verify_parity(
            pt_path,
            cfg.output_path,
            cfg.scale,
            input_shape=cfg.input_shape,
        )
        _LOG.info("parity max_abs=%.4e mean_abs=%.4e",
                  report.max_abs, report.mean_abs)
        for note in report.notes:
            _LOG.info("  %s", note)

        # Hard fail if parity is clearly broken (port bug, not drift).
        if report.max_abs > 1e-1:
            _LOG.error("parity FAILED: max_abs > 1e-1 indicates port bug")
            return 5

    return 0


if __name__ == "__main__":
    sys.exit(main())
