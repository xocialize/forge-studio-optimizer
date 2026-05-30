"""
convert_srvggnet_to_mlx.py — PyTorch → MLX safetensors converter for
the three vendored SRVGGNetCompact variants.

Per Forge-CodingPlan-v1.0.md §C playback-tier baseline (Task #28) +
ADR-0006 §"Ship criterion". Mirror of ``convert_efrlfn_to_mlx.py`` for the
Real-ESRGAN SRVGGNetCompact branch of the playback tier.

Variants
--------

| short name      | upstream file                      | num_feat | num_conv | act    | params    |
| --------------- | ---------------------------------- | -------- | -------- | ------ | --------- |
| ``general``     | ``realesr-general-x4v3.pth``       | 64       | 32       | prelu  | 1,213,296 |
| ``general-wdn`` | ``realesr-general-wdn-x4v3.pth``   | 64       | 32       | prelu  | 1,213,296 |
| ``anime``       | ``realesr-animevideov3.pth``       | 64       | 16       | prelu  |   621,424 |

Key conventions
---------------

- Conv2d weights: PyTorch ``(O, I, kH, kW)`` → MLX ``(O, kH, kW, I)``
- PReLU weights are 1-D ``(num_feat,)`` — pass through.
- Bias tensors are 1-D — pass through.
- Every weight materialized with ``mx.eval(...)`` before save (MLX is lazy —
  un-eval'd tensors serialize as zeros silently). See mlx-porting skill.
- Upstream uses ``nn.ModuleList`` for the entire `body`, so state-dict keys
  are positional ``body.{N}.weight`` / ``body.{N}.bias``. We remap to the
  named scheme the Swift port + MLX-Python reference share:

      body.0.weight, body.0.bias       → first_conv.weight, first_conv.bias
      body.1.weight                     → first_act.weight
      body.2.weight, body.2.bias       → body_pairs.0.conv.weight, .bias
      body.3.weight                     → body_pairs.0.act.weight
      ...
      body.{2k}.weight, .bias          → body_pairs.{k-1}.conv.weight, .bias
      body.{2k+1}.weight                → body_pairs.{k-1}.act.weight
      body.{2*num_conv+2}.weight, .bias→ last_conv.weight, last_conv.bias

  The remap is index-aware (depends on ``num_conv`` to identify the trailing
  ``last_conv`` index), so the variant must be known up-front; the
  ``--variant`` CLI flag selects it.

Usage
-----

    # Auto-download + convert + verify (cache under ~/.cache/srvggnet_weights):
    python convert_srvggnet_to_mlx.py \\
        --variant general \\
        --output ../ForgeUpscaler/Sources/ForgeUpscaler/Resources/realesr_general_x4.safetensors \\
        --verify-parity

    # Manual checkpoint override:
    python convert_srvggnet_to_mlx.py \\
        --variant anime \\
        --input ~/Downloads/realesr-animevideov3.pth \\
        --output realesr_anime_x4.safetensors

Plan ref
--------
- Docs/Forge-CodingPlan-v1.0.md §C (Task #28)
- Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md §"Ship criterion"
- Mirror of convert_efrlfn_to_mlx.py (Task #20) — same shape.
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import numpy as np

import mlx.core as mx

# `safetensors.numpy` is the writer; `mlx.core.load` is the reader. Same as
# the EfRLFN converter.
from safetensors.numpy import save_file as save_safetensors_numpy

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

_LOG = logging.getLogger("convert_srvggnet_to_mlx")


# ----------------------------------------------------------------------------
# Variant catalogue
# ----------------------------------------------------------------------------

@dataclass(frozen=True)
class VariantSpec:
    """Per-variant constants — upstream config + provenance."""

    name: str
    upstream_filename: str
    num_feat: int
    num_conv: int
    act_type: str  # "prelu" or "leakyrelu" (all v3 are prelu)
    upscale: int
    expected_params: int
    expected_pt_size: int   # bytes
    pt_sha256: str          # SHA-256 of the upstream .pth (pinned)

    @property
    def body_last_index(self) -> int:
        """Upstream `body.{N}` index of the trailing conv.

        Layout: first conv (0) + first act (1) + num_conv * (conv, act) +
        last conv. So the last conv sits at ``2 + 2*num_conv``.
        """
        return 2 + 2 * self.num_conv


# Pinned at 2026-05-28 from
# https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/
# Mirror (fallback): https://huggingface.co/leonelhs/realesrgan/resolve/main/<filename>
VARIANTS: dict[str, VariantSpec] = {
    "general": VariantSpec(
        name="general",
        upstream_filename="realesr-general-x4v3.pth",
        num_feat=64,
        num_conv=32,
        act_type="prelu",
        upscale=4,
        expected_params=1_213_296,
        expected_pt_size=4_885_111,
        pt_sha256="8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292",
    ),
    "general-wdn": VariantSpec(
        name="general-wdn",
        upstream_filename="realesr-general-wdn-x4v3.pth",
        num_feat=64,
        num_conv=32,
        act_type="prelu",
        upscale=4,
        expected_params=1_213_296,
        expected_pt_size=4_885_111,
        pt_sha256="1641f8c4464b9f097c9fdda5589273713f67cf59f3d909e0bd688f0cee269dca",
    ),
    "anime": VariantSpec(
        name="anime",
        upstream_filename="realesr-animevideov3.pth",
        num_feat=64,
        num_conv=16,
        act_type="prelu",
        upscale=4,
        expected_params=621_424,
        expected_pt_size=2_504_012,
        pt_sha256="b8a8376811077954d82ca3fcf476f1ac3da3e8a68a4f4d71363008000a18b75d",
    ),
}

UPSTREAM_PRIMARY_URL = (
    "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/"
)
UPSTREAM_FALLBACK_URL = (
    "https://huggingface.co/leonelhs/realesrgan/resolve/main/"
)


# ----------------------------------------------------------------------------
# Config + report dataclasses
# ----------------------------------------------------------------------------

@dataclass
class ConverterConfig:
    """Conversion + parity-check options."""

    variant: str
    input_path: Optional[Path]
    output_path: Path
    cache_dir: Optional[Path]
    verify_parity: bool
    input_shape: tuple[int, int, int, int]
    dtype: str  # "float32" or "float16"

    def __post_init__(self) -> None:
        if self.variant not in VARIANTS:
            raise ValueError(
                f"unknown variant {self.variant!r}; choose from {sorted(VARIANTS)}"
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

def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download_checkpoint(variant: str, cache_dir: Path) -> Path:
    """Fetch the upstream Real-ESRGAN SRVGGNetCompact checkpoint.

    Tries the xinntao GitHub release URL first, then the leonelhs HF mirror
    on the way down. Caches under ``cache_dir`` keyed by upstream filename.
    Verifies the pinned SHA-256 and refuses to proceed if the hash drifts.

    Args:
        variant: One of ``VARIANTS``.
        cache_dir: directory to write into. Created if missing.

    Returns:
        Path to the downloaded ``.pth`` checkpoint.

    Raises:
        ValueError: if the variant is unknown.
        RuntimeError: if both fetch endpoints fail or the SHA mismatches.
    """
    import urllib.request

    if variant not in VARIANTS:
        raise ValueError(f"unknown variant {variant!r}")
    spec = VARIANTS[variant]

    cache_dir.mkdir(parents=True, exist_ok=True)
    dst = cache_dir / spec.upstream_filename

    if dst.exists():
        actual = _sha256_file(dst)
        if actual == spec.pt_sha256:
            _LOG.info("cached checkpoint OK: %s", dst)
            return dst
        _LOG.warning(
            "cached checkpoint SHA mismatch (got %s, want %s); re-downloading",
            actual, spec.pt_sha256,
        )
        dst.unlink()

    last_exc: Optional[Exception] = None
    for base in (UPSTREAM_PRIMARY_URL, UPSTREAM_FALLBACK_URL):
        url = base + spec.upstream_filename
        _LOG.info("downloading %s weights from %s", variant, url)
        try:
            with urllib.request.urlopen(url) as resp, open(dst, "wb") as f:
                f.write(resp.read())
            break
        except Exception as e:  # noqa: BLE001
            _LOG.warning("download failed at %s: %s", url, e)
            last_exc = e
            if dst.exists():
                dst.unlink()
    else:
        # Both endpoints failed.
        assert last_exc is not None
        raise RuntimeError(
            f"all download endpoints failed for variant={variant!r}; "
            f"last error: {last_exc}. "
            f"Manual fetch: pick one of "
            f"{UPSTREAM_PRIMARY_URL}{spec.upstream_filename} or "
            f"{UPSTREAM_FALLBACK_URL}{spec.upstream_filename} and save to {dst}."
        )

    actual = _sha256_file(dst)
    if actual != spec.pt_sha256:
        raise RuntimeError(
            f"SHA mismatch after download for variant={variant!r}: "
            f"got {actual}, want {spec.pt_sha256}. Upstream weights may have "
            f"been re-uploaded — verify with the xinntao release page and "
            f"pin the new hash."
        )
    _LOG.info("downloaded + verified: %s (%d bytes)", dst, dst.stat().st_size)
    return dst


# ----------------------------------------------------------------------------
# State-dict conversion
# ----------------------------------------------------------------------------

def _is_conv2d_weight(key: str, shape: tuple[int, ...]) -> bool:
    """A 4-D weight in SRVGGNetCompact is a Conv2d kernel."""
    return key.endswith(".weight") and len(shape) == 4


def _remap_key(pt_key: str, spec: VariantSpec) -> str:
    """Translate an upstream ``body.{N}.{suffix}`` key to the Swift / MLX
    flat-name scheme.

    See the converter file's module docstring for the full mapping table.

    Layout:
        body.0          → first_conv      (Conv2d, has weight + bias)
        body.1          → first_act       (PReLU, has weight only)
        body.{2k}       → body_pairs.{k-1}.conv  for k in 1..num_conv
        body.{2k+1}     → body_pairs.{k-1}.act   for k in 1..num_conv
        body.{last_idx} → last_conv       (Conv2d, has weight + bias)
                          where last_idx = 2 + 2*num_conv
    """
    if not pt_key.startswith("body."):
        # Unexpected — upstream SRVGGNetCompact has no params outside `body`.
        # Pass through and let the verifier flag it.
        return pt_key

    _, rest = pt_key.split(".", 1)        # rest = "<N>.<suffix>"
    n_str, suffix = rest.split(".", 1)    # n_str = "<N>", suffix = "weight|bias"
    n = int(n_str)
    last_idx = spec.body_last_index

    if n == 0:
        return f"first_conv.{suffix}"
    if n == 1:
        # PReLU: the only param is `weight` (the alpha vector). Upstream
        # `nn.PReLU.weight` → MLX-Swift `PReLU.weight` (held inside the
        # ActivationLayer's `prelu` slot) → MLX-Python `_Activation.weight`.
        # Both backends expose the alpha as `.weight` at the activation
        # module's top level, so the swift / python tree shapes the upstream
        # `body.1.weight` to `first_act.weight` here. The Swift port
        # additionally re-exposes the alpha through `first_act.prelu.weight`
        # — the converter targets the upstream-faithful flat name.
        return f"first_act.{suffix}"
    if n == last_idx:
        return f"last_conv.{suffix}"

    # Body pair indices: body.{2}, body.{3} → pair 0 (conv, act);
    # body.{4}, body.{5} → pair 1; ... up to body.{last_idx - 2}, body.{last_idx - 1}.
    if 2 <= n < last_idx:
        pair_index, parity = divmod(n - 2, 2)
        sub = "conv" if parity == 0 else "act"
        return f"body_pairs.{pair_index}.{sub}.{suffix}"

    # Unknown index — pass through (the verifier will catch it).
    return pt_key


def convert_state_dict(
    pt_state_dict: dict[str, Any],
    variant: str,
    *,
    dtype: str = "float32",
) -> dict[str, mx.array]:
    """Apply the key remap + layout transpose + dtype, returning an MLX dict.

    Accepts the upstream wrapped form (``{'params': sd}``) as well as a
    bare state_dict. The Real-ESRGAN releases ship the wrapped form.

    Args:
        pt_state_dict: PyTorch state-dict. Values may be ``torch.Tensor``
            or ``numpy.ndarray`` (the tests inject NumPy directly).
        variant: One of ``VARIANTS`` — required for the index-aware remap.
        dtype: ``"float32"`` (default) or ``"float16"``. FP16 halves the
            on-disk size (~4.9 MB → ~2.5 MB for the general variants;
            ~2.5 MB → ~1.3 MB for anime).

    Returns:
        Dict keyed by Swift-side parameter name, values are ``mx.array``
        instances that have been ``mx.eval``'d.
    """
    if variant not in VARIANTS:
        raise ValueError(f"unknown variant {variant!r}")
    if dtype not in ("float32", "float16"):
        raise ValueError(f"dtype must be float32 or float16, got {dtype!r}")
    spec = VARIANTS[variant]
    target_np_dtype = np.float16 if dtype == "float16" else np.float32

    # Unwrap `{'params': sd}` if present (upstream Real-ESRGAN format).
    sd = pt_state_dict
    if (
        "params" in sd
        and isinstance(sd["params"], dict)
        and all(hasattr(v, "shape") for v in sd["params"].values())
    ):
        sd = sd["params"]
    elif (
        "params_ema" in sd
        and isinstance(sd["params_ema"], dict)
        and all(hasattr(v, "shape") for v in sd["params_ema"].values())
    ):
        sd = sd["params_ema"]

    out: dict[str, mx.array] = {}

    for key, tensor in sd.items():
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
        # PReLU weight is 1-D (num_feat,) — pass through.
        # Biases are 1-D — pass through.

        arr = arr.astype(target_np_dtype, copy=False)

        new_key = _remap_key(key, spec)
        mx_arr = mx.array(arr)
        # Force materialization. MLX is lazy — without this, save_safetensors
        # can serialize zeros silently. See mlx-porting skill §"silent killer".
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

def _build_pytorch_reference(variant: str):
    """Inline transcription of upstream ``srvgg_arch.py:SRVGGNetCompact``.

    Lives inline (rather than ``pip install basicsr``) for the same reason
    the EfRLFN converter inlines its reference: the upstream package
    introduces a heavy dependency tree just to import a 100-line model
    definition. The architecture below is verbatim per the upstream URL
    captured in this script's docstring.
    """
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    spec = VARIANTS[variant]

    class SRVGGNetCompactRef(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.num_in_ch = spec.num_in_ch if hasattr(spec, "num_in_ch") else 3
            self.num_out_ch = 3
            self.num_feat = spec.num_feat
            self.num_conv = spec.num_conv
            self.upscale = spec.upscale
            self.act_type = spec.act_type

            self.body = nn.ModuleList()
            # First conv.
            self.body.append(nn.Conv2d(3, spec.num_feat, 3, 1, 1))
            # First activation.
            self.body.append(self._make_act())

            for _ in range(spec.num_conv):
                self.body.append(
                    nn.Conv2d(spec.num_feat, spec.num_feat, 3, 1, 1)
                )
                self.body.append(self._make_act())

            self.body.append(
                nn.Conv2d(spec.num_feat, 3 * spec.upscale * spec.upscale, 3, 1, 1)
            )

        def _make_act(self) -> nn.Module:
            if spec.act_type == "relu":
                return nn.ReLU(inplace=True)
            if spec.act_type == "prelu":
                return nn.PReLU(num_parameters=spec.num_feat)
            if spec.act_type == "leakyrelu":
                return nn.LeakyReLU(negative_slope=0.1, inplace=True)
            raise ValueError(spec.act_type)

        def forward(self, x: "torch.Tensor") -> "torch.Tensor":
            out = x
            for layer in self.body:
                out = layer(out)
            out = F.pixel_shuffle(out, self.upscale)
            base = F.interpolate(x, scale_factor=self.upscale, mode="nearest")
            out = out + base
            return out

    return SRVGGNetCompactRef()


def verify_parity(
    pt_checkpoint: Path,
    mlx_safetensors: Path,
    variant: str,
    input_shape: tuple[int, int, int, int] = (1, 3, 64, 64),
    seed: int = 1234,
) -> ParityReport:
    """Run a forward pass through both backends on identical NumPy input.

    Mirror of ``convert_efrlfn_to_mlx.verify_parity`` — same threshold
    semantics. Used by the CLI's ``--verify-parity`` flag.

    Raises:
        ImportError: if PyTorch isn't installed. The caller should treat
            this as a soft skip (the unit tests use ``pytest.importorskip``).
    """
    import torch  # local — keep PyTorch out of the import path otherwise

    spec = VARIANTS[variant]
    pt_model = _build_pytorch_reference(variant)
    raw = torch.load(pt_checkpoint, map_location="cpu", weights_only=True)
    state_dict = raw.get("params", raw.get("params_ema", raw))
    pt_model.load_state_dict(state_dict, strict=True)
    pt_model.eval()

    # MLX-Python reference.
    from Python.models.srvggnet_mlx import SRVGGNetCompact as MX_SRVGGNet  # noqa: E402

    mlx_model = MX_SRVGGNet(
        num_in_ch=3, num_out_ch=3,
        num_feat=spec.num_feat, num_conv=spec.num_conv,
        upscale=spec.upscale, act_type=spec.act_type,
    )
    mlx_weights = mx.load(str(mlx_safetensors))
    mlx_model.load_weights(list(mlx_weights.items()))
    mlx_model.eval()

    rng = np.random.default_rng(seed)
    n, c, h, w = input_shape
    x_nchw = rng.standard_normal((n, c, h, w), dtype=np.float32)
    x_nhwc = np.transpose(x_nchw, (0, 2, 3, 1))

    with torch.no_grad():
        y_pt = pt_model(torch.from_numpy(x_nchw)).cpu().numpy()

    y_mlx = mlx_model(mx.array(x_nhwc))
    mx.eval(y_mlx)
    y_mlx_np = np.array(y_mlx)
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
        description="Convert SRVGGNetCompact PyTorch checkpoint → MLX safetensors.",
    )
    p.add_argument(
        "--variant", choices=sorted(VARIANTS.keys()), required=True,
        help="upstream variant to convert. Determines num_conv + body indexing.",
    )
    p.add_argument(
        "--input", "-i", type=Path, default=None,
        help="path to upstream PyTorch .pth; omit to auto-download via --cache-dir.",
    )
    p.add_argument(
        "--output", "-o", type=Path, required=True,
        help="output safetensors path.",
    )
    p.add_argument(
        "--cache-dir", type=Path,
        default=Path.home() / ".cache" / "srvggnet_weights",
        help="where to cache the upstream checkpoint when auto-downloading.",
    )
    p.add_argument(
        "--dtype", choices=("float32", "float16"), default="float16",
        help="on-disk weight dtype. float16 halves bundle size (general: "
             "~4.9 MB → ~2.5 MB; anime: ~2.5 MB → ~1.3 MB).",
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
        variant=args.variant,
        input_path=args.input,
        output_path=args.output,
        cache_dir=args.cache_dir,
        verify_parity=args.verify_parity,
        input_shape=args.input_shape,
        dtype=args.dtype,
    )
    spec = VARIANTS[cfg.variant]

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
        pt_path = download_checkpoint(cfg.variant, cfg.cache_dir)

    # 2. Load state dict.
    try:
        import torch
    except ImportError:
        _LOG.error(
            "torch is required to read .pth checkpoints. "
            "Install via: pip install -r requirements-parity.txt"
        )
        return 3

    raw = torch.load(pt_path, map_location="cpu", weights_only=True)
    state_dict = raw.get("params", raw.get("params_ema", raw))
    n_params = sum(int(np.prod(v.shape)) for v in state_dict.values())
    if n_params != spec.expected_params:
        _LOG.warning(
            "param count %d does not match expected %d for variant=%s "
            "(pinned at this script's VARIANTS table). Proceeding, but "
            "expect the Swift loader's verify=.noUnusedKeys to flag this.",
            n_params, spec.expected_params, cfg.variant,
        )
    else:
        _LOG.info(
            "param count %d matches expected for variant=%s",
            n_params, cfg.variant,
        )

    # 3. Convert.
    mlx_state = convert_state_dict(state_dict, cfg.variant, dtype=cfg.dtype)
    _LOG.info("converted %d keys (PT) → %d keys (MLX)",
              len(state_dict), len(mlx_state))

    # 4. Save.
    save_mlx_weights(mlx_state, cfg.output_path)

    # 5. Round-trip sanity.
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
            cfg.variant,
            input_shape=cfg.input_shape,
        )
        _LOG.info("parity max_abs=%.4e mean_abs=%.4e",
                  report.max_abs, report.mean_abs)
        for note in report.notes:
            _LOG.info("  %s", note)

        if report.max_abs > 1e-1:
            _LOG.error("parity FAILED: max_abs > 1e-1 indicates port bug")
            return 5

    return 0


if __name__ == "__main__":
    sys.exit(main())
