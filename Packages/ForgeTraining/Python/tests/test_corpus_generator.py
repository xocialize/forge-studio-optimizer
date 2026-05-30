"""End-to-end tests for the corpus generator CLI.

Covers:
    - Deterministic re-runs given the same seed (byte-identical manifest +
      first N pairs).
    - ``--skip-degradation`` honored across the whole run.
    - Output schema sanity: pair count, paired-PNG/meta-JSON layout, manifest
      fields the trainer relies on.

These tests spawn a small in-tree corpus (very few pairs) so they fit in CI
seconds, but they exercise the full ProcessPoolExecutor path.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

# Allow direct invocation: prepend Packages/ForgeTraining so `Python.*` resolves.
HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent.parent.parent))  # Packages/ForgeTraining/

from Python import generate_multidegradation_corpus as gen  # noqa: E402


# ----------------------------------------------------------------------------
# Fixtures
# ----------------------------------------------------------------------------

def _make_source_images(root: Path, n: int = 5, size: int = 384) -> list[Path]:
    """Create N synthetic source images with varying gradients/textures."""
    root.mkdir(parents=True, exist_ok=True)
    paths: list[Path] = []
    for i in range(n):
        rng = np.random.default_rng(1000 + i)
        yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
        r = ((xx + i * 30) / size) * 255.0
        g = ((yy + i * 17) / size) * 255.0
        b = (((xx + yy + i * 13) % size) / size) * 255.0
        img = np.stack([r, g, b], axis=-1)
        img += rng.normal(0, 5, img.shape).astype(np.float32)
        img = np.clip(img, 0, 255).astype(np.uint8)
        # Inject a couple of high-contrast rectangles for codec stress.
        img[20:60, 20:60] = [255, 0, 0]
        img[80:140, 80:140] = [0, 255, 0]
        path = root / f"src_{i:03d}.png"
        Image.fromarray(img, mode="RGB").save(path, format="PNG")
        paths.append(path)
    return paths


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


@pytest.fixture(scope="module")
def source_dir(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Shared 5-image source dir for the module."""
    src = tmp_path_factory.mktemp("forge_train_src")
    _make_source_images(src, n=5, size=384)
    return src


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

def _run(source_dir: Path, output: Path, **kwargs) -> int:
    """Invoke the CLI's ``main()`` with the given kwargs (forced to single
    worker for byte-determinism between runs)."""
    argv = [
        "--hq-source", str(source_dir),
        "--output", str(output),
        "--num-pairs", str(kwargs.pop("num_pairs", 8)),
        "--tile-size", str(kwargs.pop("tile_size", 64)),
        "--seed", str(kwargs.pop("seed", 42)),
        "--workers", str(kwargs.pop("workers", 1)),
    ]
    for skip in kwargs.pop("skip", []):
        argv += ["--skip-degradation", skip]
    if kwargs.pop("resume", False):
        argv += ["--resume"]
    assert not kwargs, f"unused test kwargs: {kwargs}"
    return gen.main(argv)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------

class TestCorpusOutputShape:

    def test_produces_expected_pair_count(
        self, source_dir: Path, tmp_path: Path
    ) -> None:
        out = tmp_path / "corpus"
        rc = _run(source_dir, out, num_pairs=8, seed=7)
        assert rc == 0

        pairs_dir = out / "pairs"
        hq = sorted(pairs_dir.glob("*_hq.png"))
        lq = sorted(pairs_dir.glob("*_lq.png"))
        meta = sorted(pairs_dir.glob("*_meta.json"))
        assert len(hq) == 8
        assert len(lq) == 8
        assert len(meta) == 8

        # All pairs are 64x64 RGB.
        for p in hq + lq:
            with Image.open(p) as im:
                assert im.size == (64, 64)
                assert im.mode == "RGB"

    def test_manifest_schema(self, source_dir: Path, tmp_path: Path) -> None:
        out = tmp_path / "corpus"
        rc = _run(source_dir, out, num_pairs=8, seed=11)
        assert rc == 0

        with open(out / "manifest.json", "r", encoding="utf-8") as f:
            m = json.load(f)
        assert m["version"] == 1
        assert m["seed"] == 11
        assert m["tile_size"] == 64
        assert m["num_pairs"] == 8
        assert m["target_pairs"] == 8
        assert m["finalized"] is True
        assert set(m["breakdown"].keys()) == {"noise", "hevc", "av1", "mpeg2"}
        assert sum(m["breakdown"].values()) == 8
        assert isinstance(m["source_sha"], str) and len(m["source_sha"]) == 64
        assert m["skipped_degradations"] == []


class TestDeterminism:

    def test_two_runs_byte_identical(self, source_dir: Path, tmp_path: Path) -> None:
        """Same seed + same source dir => identical manifest + identical first
        10 pairs (we generate 10 here)."""
        out_a = tmp_path / "run_a"
        out_b = tmp_path / "run_b"
        rc_a = _run(source_dir, out_a, num_pairs=10, seed=99)
        rc_b = _run(source_dir, out_b, num_pairs=10, seed=99)
        assert rc_a == 0 and rc_b == 0

        # Manifest comparison: drop the volatile `updated_at` + `ffmpeg`
        # absolute paths (the latter is identical between runs anyway) and
        # compare the structural payload.
        with open(out_a / "manifest.json") as f:
            ma = json.load(f)
        with open(out_b / "manifest.json") as f:
            mb = json.load(f)
        ma.pop("updated_at", None)
        mb.pop("updated_at", None)
        assert ma == mb, "manifests differ between deterministic runs"

        # Pair file bytes: HQ + LQ + meta should all match for every index.
        for idx in range(10):
            stem = f"{idx:06d}"
            for suffix in ("_hq.png", "_lq.png", "_meta.json"):
                pa = out_a / "pairs" / f"{stem}{suffix}"
                pb = out_b / "pairs" / f"{stem}{suffix}"
                assert pa.exists() and pb.exists()
                assert _sha256_file(pa) == _sha256_file(pb), (
                    f"non-deterministic byte output for {stem}{suffix}"
                )


class TestSkipDegradation:

    def test_skip_removes_kind_from_breakdown(
        self, source_dir: Path, tmp_path: Path
    ) -> None:
        """If we skip AV1 (the slowest) and MPEG-2, every pair must be
        noise/hevc and the manifest must reflect that."""
        out = tmp_path / "corpus_skip"
        rc = _run(
            source_dir, out,
            num_pairs=12, seed=5,
            skip=["av1", "mpeg2"],
        )
        assert rc == 0

        with open(out / "manifest.json") as f:
            m = json.load(f)
        assert sorted(m["skipped_degradations"]) == ["av1", "mpeg2"]
        assert m["breakdown"]["av1"] == 0
        assert m["breakdown"]["mpeg2"] == 0
        assert m["breakdown"]["noise"] + m["breakdown"]["hevc"] == 12

        # Also verify by reading every per-pair meta — no av1/mpeg2 leaked in.
        for meta_path in (out / "pairs").glob("*_meta.json"):
            with open(meta_path) as f:
                meta = json.load(f)
            assert meta["degradation"] in {"noise", "hevc"}, (
                f"skipped degradation leaked into {meta_path.name}: {meta['degradation']}"
            )

    def test_skip_all_fails_cleanly(self, source_dir: Path, tmp_path: Path) -> None:
        out = tmp_path / "corpus_skip_all"
        rc = gen.main([
            "--hq-source", str(source_dir),
            "--output", str(out),
            "--num-pairs", "4",
            "--tile-size", "64",
            "--workers", "1",
            "--skip-degradation", "noise",
            "--skip-degradation", "hevc",
            "--skip-degradation", "av1",
            "--skip-degradation", "mpeg2",
        ])
        assert rc != 0


class TestResume:

    def test_resume_keeps_existing_and_extends(
        self, source_dir: Path, tmp_path: Path
    ) -> None:
        out = tmp_path / "corpus_resume"
        # First run: 4 pairs.
        assert _run(source_dir, out, num_pairs=4, seed=3) == 0
        first_hashes = {
            p.name: _sha256_file(p)
            for p in (out / "pairs").glob("*")
        }
        assert len([k for k in first_hashes if k.endswith("_hq.png")]) == 4

        # Second run: 6 pairs total with --resume. Indices 0..3 must be
        # byte-identical; indices 4 + 5 are new.
        assert _run(source_dir, out, num_pairs=6, seed=3, resume=True) == 0
        for name, h in first_hashes.items():
            assert _sha256_file(out / "pairs" / name) == h, (
                f"--resume mutated existing pair file {name}"
            )
        hq_files = sorted((out / "pairs").glob("*_hq.png"))
        assert len(hq_files) == 6

        with open(out / "manifest.json") as f:
            m = json.load(f)
        assert m["num_pairs"] == 6
        assert m["finalized"] is True
        assert sum(m["breakdown"].values()) == 6
