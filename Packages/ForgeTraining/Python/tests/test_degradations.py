"""Unit tests for :mod:`Python.degradations`.

Validates shape preservation and degradation magnitude bands. The ffmpeg
tests will be skipped automatically if libx265 / libaom / mpeg2video aren't
available on this host's ffmpeg build.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

# Allow running tests directly from the repo without installing the package.
HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent.parent.parent))  # Packages/ForgeTraining/

from Python import degradations as deg  # noqa: E402


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

def _ffmpeg_supports(encoder: str) -> bool:
    """Return True if the host ffmpeg lists the given encoder."""
    try:
        ffmpeg = deg.locate_ffmpeg()
    except FileNotFoundError:
        return False
    try:
        out = subprocess.run(
            [ffmpeg, "-hide_banner", "-encoders"],
            capture_output=True, text=True, check=True,
        ).stdout
    except subprocess.CalledProcessError:
        return False
    return encoder in out


def _synthetic_tile(seed: int = 0, size: int = 128) -> np.ndarray:
    """Build a synthetic RGB tile with enough structure for codecs to chew on.

    Uses smooth gradients + a few high-contrast blocks so quality measures
    aren't pinned at a single value.
    """
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    r = (xx / size) * 255.0
    g = (yy / size) * 255.0
    b = ((xx + yy) / (2 * size)) * 255.0
    img = np.stack([r, g, b], axis=-1)
    # Add a few hard-edged blocks for codec stress.
    img[10:30, 10:30] = [255, 0, 0]
    img[40:80, 40:80] = [0, 255, 0]
    img[60:100, 10:50] = [0, 0, 255]
    # Light noise to defeat trivial flat-region encoding.
    img += rng.normal(0, 3, img.shape).astype(np.float32)
    return np.clip(img, 0, 255).astype(np.uint8)


# ----------------------------------------------------------------------------
# Gaussian noise
# ----------------------------------------------------------------------------

class TestGaussianNoise:

    def test_shape_and_dtype_preserved(self) -> None:
        img = _synthetic_tile(seed=1, size=64)
        out = deg.gaussian_noise(img, sigma=15.0, rng=np.random.default_rng(0))
        assert out.shape == img.shape
        assert out.dtype == np.uint8

    def test_input_not_mutated(self) -> None:
        img = _synthetic_tile(seed=2, size=64)
        snapshot = img.copy()
        _ = deg.gaussian_noise(img, sigma=20.0, rng=np.random.default_rng(0))
        np.testing.assert_array_equal(img, snapshot)

    @pytest.mark.parametrize("sigma", [5.0, 15.0, 30.0, 50.0])
    def test_mad_in_expected_band(self, sigma: float) -> None:
        """Mean absolute deviation should track sigma * sqrt(2/pi).

        For a half-normal distribution E[|X|] = sigma * sqrt(2/pi) ≈ 0.7979 * sigma.
        Clipping at [0, 255] slightly biases the observed MAD downward; we
        check a generous band that's still tight enough to catch the wrong
        scale entirely.
        """
        img = _synthetic_tile(seed=3, size=128)
        out = deg.gaussian_noise(img, sigma=sigma, rng=np.random.default_rng(0))
        mad = float(np.mean(np.abs(out.astype(np.int16) - img.astype(np.int16))))
        expected = 0.7979 * sigma
        # Wide band: noise on near-saturated pixels clips, dragging MAD down.
        assert 0.55 * expected <= mad <= 1.15 * expected, (
            f"sigma={sigma}: MAD={mad:.2f}, expected≈{expected:.2f}"
        )

    def test_determinism_with_seeded_rng(self) -> None:
        img = _synthetic_tile(seed=4, size=64)
        a = deg.gaussian_noise(img, sigma=25.0, rng=np.random.default_rng(123))
        b = deg.gaussian_noise(img, sigma=25.0, rng=np.random.default_rng(123))
        np.testing.assert_array_equal(a, b)

    def test_rejects_non_rgb(self) -> None:
        with pytest.raises(ValueError):
            deg.gaussian_noise(np.zeros((32, 32), dtype=np.uint8), sigma=10.0)
        with pytest.raises(ValueError):
            deg.gaussian_noise(np.zeros((32, 32, 4), dtype=np.uint8), sigma=10.0)


# ----------------------------------------------------------------------------
# Codec round trips
# ----------------------------------------------------------------------------

@pytest.mark.skipif(not _ffmpeg_supports("libx265"), reason="ffmpeg lacks libx265")
class TestHEVC:

    def test_shape_preserved(self) -> None:
        img = _synthetic_tile(seed=10, size=128)
        out = deg.encode_hevc(img, crf=28)
        assert out.shape == img.shape
        assert out.dtype == np.uint8

    @pytest.mark.parametrize("crf", [22, 28, 35])
    def test_psnr_in_plausible_band(self, crf: int) -> None:
        """HEVC at coding-plan CRF range should yield PSNR roughly 25-50 dB."""
        img = _synthetic_tile(seed=11, size=128)
        out = deg.encode_hevc(img, crf=crf)
        p = deg.psnr(img, out)
        assert 20.0 < p < 55.0, f"HEVC crf={crf} PSNR={p:.2f} out of band"

    def test_rejects_odd_dimensions(self) -> None:
        odd = _synthetic_tile(seed=12, size=64)[:63, :64]
        with pytest.raises(ValueError):
            deg.encode_hevc(odd, crf=28)


@pytest.mark.skipif(not _ffmpeg_supports("libaom-av1"), reason="ffmpeg lacks libaom-av1")
class TestAV1:

    def test_shape_preserved(self) -> None:
        img = _synthetic_tile(seed=20, size=128)
        out = deg.encode_av1(img, crf=32)
        assert out.shape == img.shape
        assert out.dtype == np.uint8

    @pytest.mark.parametrize("crf", [25, 32, 40])
    def test_psnr_in_plausible_band(self, crf: int) -> None:
        img = _synthetic_tile(seed=21, size=128)
        out = deg.encode_av1(img, crf=crf)
        p = deg.psnr(img, out)
        assert 18.0 < p < 55.0, f"AV1 crf={crf} PSNR={p:.2f} out of band"


@pytest.mark.skipif(not _ffmpeg_supports("mpeg2video"), reason="ffmpeg lacks mpeg2video")
class TestMPEG2:

    def test_shape_preserved(self) -> None:
        img = _synthetic_tile(seed=30, size=128)
        out = deg.encode_mpeg2(img, bitrate_mbps=4.0)
        assert out.shape == img.shape
        assert out.dtype == np.uint8

    @pytest.mark.parametrize("bitrate_mbps", [2.0, 5.0, 8.0])
    def test_psnr_in_plausible_band(self, bitrate_mbps: float) -> None:
        img = _synthetic_tile(seed=31, size=128)
        out = deg.encode_mpeg2(img, bitrate_mbps=bitrate_mbps)
        p = deg.psnr(img, out)
        # MPEG-2 on a tiny tile is noisy; band is intentionally wide.
        assert 15.0 < p < 55.0, (
            f"MPEG-2 br={bitrate_mbps} Mbps PSNR={p:.2f} out of band"
        )


# ----------------------------------------------------------------------------
# Dispatcher
# ----------------------------------------------------------------------------

class TestApplyDegradation:

    def test_noise_dispatch(self) -> None:
        img = _synthetic_tile(seed=40, size=64)
        out = deg.apply_degradation(img, "noise", 20.0, rng=np.random.default_rng(0))
        assert out.shape == img.shape

    def test_unknown_kind_raises(self) -> None:
        img = _synthetic_tile(seed=41, size=64)
        with pytest.raises(ValueError):
            deg.apply_degradation(img, "bogus", 1.0)


# ----------------------------------------------------------------------------
# ffmpeg discovery
# ----------------------------------------------------------------------------

class TestLocateFFmpeg:

    def test_returns_absolute_path(self) -> None:
        path = deg.locate_ffmpeg()
        assert os.path.isabs(path)
        assert os.access(path, os.X_OK)


# ----------------------------------------------------------------------------
# psnr utility
# ----------------------------------------------------------------------------

class TestPSNR:

    def test_identical_is_inf(self) -> None:
        img = _synthetic_tile(seed=50, size=32)
        assert deg.psnr(img, img) == float("inf")

    def test_shape_mismatch_raises(self) -> None:
        a = np.zeros((32, 32, 3), dtype=np.uint8)
        b = np.zeros((32, 33, 3), dtype=np.uint8)
        with pytest.raises(ValueError):
            deg.psnr(a, b)
