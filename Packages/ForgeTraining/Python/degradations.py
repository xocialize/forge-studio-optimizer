"""Per-degradation helpers for the NAFNet corpus generator.

Each public function takes an RGB ``uint8`` ``ndarray`` of shape ``(H, W, 3)``
and returns a degraded ``ndarray`` of the same shape and dtype.

Design rules:
    - ``gaussian_noise`` is pure numpy — no I/O, no subprocess.
    - The codec helpers (``encode_hevc`` / ``encode_av1`` / ``encode_mpeg2``)
      shell out to ``ffmpeg`` via subprocess, writing to / reading from a
      temp directory that is cleaned up before return.
    - All ffmpeg invocations pass ``-loglevel error -y`` so failures are
      visible and the runner never blocks on stdin.

These functions are intentionally side-effect-free at the caller's data
level: the input array is never mutated, and the returned array is a fresh
allocation.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

import numpy as np
from PIL import Image


# ----------------------------------------------------------------------------
# ffmpeg discovery
# ----------------------------------------------------------------------------

_FFMPEG_FULL = "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"


def locate_ffmpeg() -> str:
    """Return an absolute path to a usable ffmpeg binary.

    Preference order matches Forge/Tests/Corpus/scripts/fetch_corpus.sh:
        1. ``/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg`` (full codec set:
           libaom, libx265, mpeg2video).
        2. ``FFMPEG`` env var if set and executable.
        3. ``ffmpeg`` on ``PATH``.

    Raises:
        FileNotFoundError: if no usable ffmpeg is found.
    """
    if os.path.isfile(_FFMPEG_FULL) and os.access(_FFMPEG_FULL, os.X_OK):
        return _FFMPEG_FULL

    env_override = os.environ.get("FFMPEG")
    if env_override and os.path.isfile(env_override) and os.access(env_override, os.X_OK):
        return env_override

    path_ffmpeg = shutil.which("ffmpeg")
    if path_ffmpeg:
        return path_ffmpeg

    raise FileNotFoundError(
        "ffmpeg not found. Install ffmpeg-full via "
        "'brew install ffmpeg-full' (homebrew-ffmpeg/ffmpeg tap) or set $FFMPEG."
    )


# ----------------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------------

def _validate_rgb_uint8(img: np.ndarray) -> None:
    if img.ndim != 3 or img.shape[2] != 3:
        raise ValueError(f"expected (H, W, 3) RGB image, got shape {img.shape}")
    if img.dtype != np.uint8:
        raise ValueError(f"expected uint8, got dtype {img.dtype}")


def _ensure_even(n: int) -> int:
    """Most video codecs require even dimensions."""
    return n if n % 2 == 0 else n - 1


def _write_png(path: Path, img: np.ndarray) -> None:
    """Write an RGB uint8 ndarray as a lossless PNG via Pillow."""
    Image.fromarray(img, mode="RGB").save(path, format="PNG", compress_level=1)


def _read_png(path: Path) -> np.ndarray:
    """Read a PNG into an RGB uint8 ndarray."""
    with Image.open(path) as im:
        return np.asarray(im.convert("RGB"), dtype=np.uint8)


def _run_ffmpeg(args: list[str]) -> None:
    """Run ffmpeg with check=True, capturing stderr for error reporting."""
    proc = subprocess.run(
        args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(
            f"ffmpeg failed (exit {proc.returncode}): {' '.join(args)}\n{stderr}"
        )


def _codec_roundtrip(
    img: np.ndarray,
    encode_args: list[str],
    container_ext: str,
    ffmpeg_bin: Optional[str] = None,
) -> np.ndarray:
    """Generic encode-then-decode round trip.

    Writes the input as a single-frame PNG, encodes it through ffmpeg with
    the given codec args, decodes the resulting bitstream back to a PNG,
    and returns the decoded RGB array.

    Args:
        img: RGB uint8 (H, W, 3). Must already have even dimensions for
            video codecs; the caller is responsible.
        encode_args: ffmpeg encoder arguments inserted between ``-i`` and
            the output file. e.g. ``["-c:v", "libx265", "-crf", "28"]``.
        container_ext: ``".mp4"``, ``".mkv"``, etc. Matched to the codec.
        ffmpeg_bin: optional ffmpeg path override (defaults to
            ``locate_ffmpeg()``).

    Returns:
        Decoded RGB uint8 (H, W, 3).
    """
    _validate_rgb_uint8(img)
    h, w, _ = img.shape
    if h % 2 or w % 2:
        raise ValueError(
            f"video codecs require even dimensions, got {h}x{w}. "
            "Crop to even sizes before calling."
        )

    ffmpeg = ffmpeg_bin or locate_ffmpeg()

    with tempfile.TemporaryDirectory(prefix="forge_train_codec_") as tmp:
        tmpdir = Path(tmp)
        src_png = tmpdir / "src.png"
        encoded = tmpdir / f"out{container_ext}"
        dst_png = tmpdir / "dst.png"

        _write_png(src_png, img)

        # Encode: PNG -> codec bitstream
        encode_cmd = [
            ffmpeg, "-loglevel", "error", "-y",
            "-f", "image2", "-i", str(src_png),
            "-pix_fmt", "yuv420p",
            *encode_args,
            "-frames:v", "1",
            str(encoded),
        ]
        _run_ffmpeg(encode_cmd)

        # Decode: codec bitstream -> PNG
        decode_cmd = [
            ffmpeg, "-loglevel", "error", "-y",
            "-i", str(encoded),
            "-frames:v", "1",
            str(dst_png),
        ]
        _run_ffmpeg(decode_cmd)

        return _read_png(dst_png)


# ----------------------------------------------------------------------------
# Public degradation functions
# ----------------------------------------------------------------------------

def gaussian_noise(
    img: np.ndarray,
    sigma: float,
    rng: Optional[np.random.Generator] = None,
) -> np.ndarray:
    """Add per-channel zero-mean Gaussian noise.

    Args:
        img: RGB uint8 (H, W, 3).
        sigma: Noise standard deviation in 0-255 units. Coding plan range
            is ``U[5, 50]``.
        rng: Optional numpy Generator for determinism. If ``None``, the
            default generator is used.

    Returns:
        Noisy RGB uint8 (H, W, 3).
    """
    _validate_rgb_uint8(img)
    if sigma < 0:
        raise ValueError(f"sigma must be >= 0, got {sigma}")

    g = rng if rng is not None else np.random.default_rng()
    noise = g.normal(loc=0.0, scale=float(sigma), size=img.shape)
    noisy = img.astype(np.float32) + noise.astype(np.float32)
    return np.clip(noisy, 0.0, 255.0).astype(np.uint8)


def encode_hevc(
    img: np.ndarray,
    crf: int,
    ffmpeg_bin: Optional[str] = None,
) -> np.ndarray:
    """HEVC (libx265) encode-decode round trip.

    Args:
        img: RGB uint8 (H, W, 3), even dimensions.
        crf: x265 CRF. Coding plan range ``U[22, 35]``.
        ffmpeg_bin: optional override.

    Returns:
        Decoded RGB uint8.
    """
    if not 0 <= crf <= 51:
        raise ValueError(f"HEVC CRF must be 0..51, got {crf}")
    return _codec_roundtrip(
        img,
        encode_args=[
            "-c:v", "libx265",
            "-preset", "medium",
            "-crf", str(int(crf)),
            # Quiet the libx265 banner so '-loglevel error' actually stays quiet.
            "-x265-params", "log-level=error",
        ],
        # Matroska, not .mp4: this ffmpeg-full build cannot mux single-frame
        # HEVC into ISOBMFF (mp4/mov) — "Not yet implemented, patches welcome".
        # .mkv (same container AV1 uses here) muxes + decodes cleanly. The
        # container is irrelevant to the libx265/CRF compression artifact we
        # actually want, so this is a pure robustness swap.
        container_ext=".mkv",
        ffmpeg_bin=ffmpeg_bin,
    )


def encode_av1(
    img: np.ndarray,
    crf: int,
    ffmpeg_bin: Optional[str] = None,
) -> np.ndarray:
    """AV1 (libaom-av1) encode-decode round trip.

    Args:
        img: RGB uint8 (H, W, 3), even dimensions.
        crf: libaom CRF. Coding plan range ``U[25, 40]``.
        ffmpeg_bin: optional override.

    Returns:
        Decoded RGB uint8.
    """
    if not 0 <= crf <= 63:
        raise ValueError(f"AV1 CRF must be 0..63, got {crf}")
    return _codec_roundtrip(
        img,
        encode_args=[
            "-c:v", "libaom-av1",
            "-strict", "experimental",
            "-crf", str(int(crf)),
            "-b:v", "0",
            "-cpu-used", "6",  # decent speed/quality trade for corpus generation
        ],
        container_ext=".mkv",
        ffmpeg_bin=ffmpeg_bin,
    )


def encode_mpeg2(
    img: np.ndarray,
    bitrate_mbps: float,
    ffmpeg_bin: Optional[str] = None,
) -> np.ndarray:
    """MPEG-2 encode-decode round trip.

    Args:
        img: RGB uint8 (H, W, 3), even dimensions.
        bitrate_mbps: Bitrate in Mbps. Coding plan range ``U[2, 8]``.
        ffmpeg_bin: optional override.

    Returns:
        Decoded RGB uint8.
    """
    if bitrate_mbps <= 0:
        raise ValueError(f"bitrate_mbps must be > 0, got {bitrate_mbps}")
    bitrate_bps = int(round(bitrate_mbps * 1_000_000))
    return _codec_roundtrip(
        img,
        encode_args=[
            "-c:v", "mpeg2video",
            "-b:v", str(bitrate_bps),
            "-bf", "2",
            "-g", "15",
        ],
        container_ext=".m2v",
        ffmpeg_bin=ffmpeg_bin,
    )


# ----------------------------------------------------------------------------
# Convenience dispatcher
# ----------------------------------------------------------------------------

DEGRADATION_KINDS = ("noise", "hevc", "av1", "mpeg2")


def apply_degradation(
    img: np.ndarray,
    kind: str,
    param: float,
    rng: Optional[np.random.Generator] = None,
    ffmpeg_bin: Optional[str] = None,
) -> np.ndarray:
    """Dispatch to the right helper given a kind string.

    Args:
        img: RGB uint8.
        kind: one of ``"noise"``, ``"hevc"``, ``"av1"``, ``"mpeg2"``.
        param: sigma for noise; CRF for hevc/av1; bitrate (Mbps) for mpeg2.
        rng: forwarded to ``gaussian_noise`` (ignored by codec helpers).
        ffmpeg_bin: forwarded to codec helpers (ignored by noise).

    Returns:
        Degraded RGB uint8.
    """
    if kind == "noise":
        return gaussian_noise(img, sigma=float(param), rng=rng)
    if kind == "hevc":
        return encode_hevc(img, crf=int(param), ffmpeg_bin=ffmpeg_bin)
    if kind == "av1":
        return encode_av1(img, crf=int(param), ffmpeg_bin=ffmpeg_bin)
    if kind == "mpeg2":
        return encode_mpeg2(img, bitrate_mbps=float(param), ffmpeg_bin=ffmpeg_bin)
    raise ValueError(
        f"unknown degradation kind {kind!r}; must be one of {DEGRADATION_KINDS}"
    )


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    """Peak signal-to-noise ratio for two uint8 RGB arrays.

    Returns ``float('inf')`` for identical inputs.
    """
    if a.shape != b.shape:
        raise ValueError(f"shape mismatch: {a.shape} vs {b.shape}")
    diff = a.astype(np.float64) - b.astype(np.float64)
    mse = float(np.mean(diff * diff))
    if mse == 0.0:
        return float("inf")
    return 10.0 * float(np.log10((255.0 ** 2) / mse))
