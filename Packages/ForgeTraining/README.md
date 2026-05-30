# ForgeTraining

Offline Python tooling for Forge's AI training runs. **Never ships with `Forge.app`.**
Per `CLAUDE.md` and Coding Plan §0, this package is build-time / dev-time only —
no Python is linked into the macOS app, and nothing here is touched at runtime.

This package now hosts two distinct tools:

1. **NAFNet corpus generator** (Phase B.2 / Task #11). Generates the paired
   HQ/LQ tile corpus that Phase B.3 (`train_nafnet.py`) will train against.
   Code lives under `Python/`.
2. **EfRLFN PyTorch → MLX converter** (Phase C.3 / Task #20). Translates the
   upstream MIT-licensed EfRLFN PyTorch checkpoint into a safetensors file
   that the Swift `ForgeUpscaler.EfRLFN` module can load. Code lives under
   `Scripts/` + `Python/models/` (MLX-Python reference for parity).

## Purpose

NAFNet (the rescoped lightweight image restoration network — see
`Docs/ADRs/0003-nafnet-sizing-rescope.md`) needs ~500k paired tiles spanning
the four real-world degradations Forge handles at decode time:

| Degradation     | Parameter         | Range                |
| --------------- | ----------------- | -------------------- |
| Gaussian noise  | sigma             | `U[5, 50]`           |
| HEVC (libx265)  | CRF               | `U[22, 35]`          |
| AV1 (libaom)    | CRF               | `U[25, 40]`          |
| MPEG-2          | bitrate (Mbps)    | `U[2, 8]`            |

Each pair is a **256x256** RGB tile (HQ = clean crop, LQ = degraded crop), with
a sibling JSON recording the degradation type + param + source provenance so
the training set is fully reproducible from `--seed`.

## Why off-device

The runtime app uses **CoreML / MLX-Swift** for inference (see `ForgeOptimizer`
and `ForgeUpscaler`). Training, dataset prep, and model evaluation all happen
off-device on an M5 Max workstation. Keeping the Python rig in
`Packages/ForgeTraining/` makes the boundary obvious: nothing in this
directory is referenced by `Package.swift` or the Xcode workspace.

## Quick start

```bash
# 1. Bootstrap venv (one-time, idempotent)
./setup.sh

# 2. Activate
source .venv/bin/activate

# 3. Generate a small test corpus (20 pairs from 5 source images)
python Python/generate_multidegradation_corpus.py \
    --hq-source /path/to/small_test_dir \
    --output /tmp/forge_corpus_smoke \
    --num-pairs 20 \
    --seed 42

# 4. Full run (target: 500k pairs, ~6-10 h wall time on M5 Max)
python Python/generate_multidegradation_corpus.py \
    --hq-source /path/to/DIV2K+Flickr2K_HR \
    --output /Volumes/Training/forge_nafnet_corpus_v1 \
    --num-pairs 500000 \
    --seed 42 \
    --workers 14
```

## CLI flags

| Flag                  | Default                          | Notes |
| --------------------- | -------------------------------- | ----- |
| `--hq-source`         | required                         | Directory of clean HQ images (recursed). PNG/JPG/JPEG/BMP/TIFF/WebP. |
| `--output`            | required                         | Output root. Tile pairs go in `<output>/pairs/`, manifest in `<output>/manifest.json`. |
| `--num-pairs`         | `500000`                         | Target pair count. With `--resume`, this is the *final* target — already-written pairs are kept. |
| `--tile-size`         | `256`                            | Per coding plan §B.2. NAFNet input is 256x256x3 NHWC. |
| `--seed`              | `42`                             | Deterministic given the same source dir + seed. |
| `--workers`           | `os.cpu_count() - 2`             | Process-pool size. ffmpeg subprocess is the bottleneck, not Python. |
| `--skip-degradation`  | (repeatable)                     | One of `noise`, `hevc`, `av1`, `mpeg2`. Strips that family from the uniform sampler. |
| `--resume`            | off                              | Skip indices that already exist; append to the manifest. |

## Hardware budget

Reference target: **M5 Max, 16 perf cores, 64 GB RAM**.

| Step                          | Wall time     | Notes |
| ----------------------------- | ------------- | ----- |
| `setup.sh`                    | ~30 s         | pip install of 5 wheels. |
| 1k smoke pairs                | ~1-2 min      | Most time is ffmpeg AV1 encode. |
| 500k full corpus              | ~6-10 h       | ~14 workers, AV1 dominates (~3-4x slower than HEVC). |
| Disk footprint (500k pairs)   | ~50-80 GB     | 256x256 PNG pairs + tiny meta JSON. |
| Peak RAM                      | ~6-8 GB       | One source image per worker in flight. |

The data-prep run is **not** the 4-day NAFNet training itself; see Phase B.3 for that.

## Source datasets (user-fetched)

The CLI does **not** download datasets. Fetch these once and point
`--hq-source` at the extracted HR directory:

| Dataset    | URL                                                                | License        | Notes |
| ---------- | ------------------------------------------------------------------ | -------------- | ----- |
| DIV2K      | https://data.vision.ee.ethz.ch/cvl/DIV2K/DIV2K_train_HR.zip        | CC BY 4.0      | 800 2K images, primary HR source. |
| Flickr2K   | https://cv.snu.ac.kr/research/EDSR/Flickr2K.tar                    | research-only  | 2650 2K images, extra diversity. |
| SIDD (eval)| https://www.eecs.yorku.ca/~kamel/sidd/dataset.php                  | research-only  | Held-out real-noise eval set for Phase B.3. Not used by this generator. |

Checksums (verify with `shasum -a 256 <file>`):

```
# DIV2K_train_HR.zip
bdc2d9338d4e574fe81bf7d158758658f5e5e7c4f3d3b69d76e6f70b9e6f6c5b  DIV2K_train_HR.zip
# Flickr2K.tar — checksum varies by mirror; verify image count after extract:
#   find Flickr2K/Flickr2K_HR -name '*.png' | wc -l   →  2650
```

*(DIV2K checksum is illustrative; verify against the EE-ETH page at download time —
the official site does not publish a stable SHA-256.)*

## Output format

```
<output>/
├── manifest.json                   # top-level: seed, source SHA, totals, per-degradation breakdown
└── pairs/
    ├── 000000_hq.png               # 256x256 RGB, lossless PNG
    ├── 000000_lq.png               # 256x256 RGB, lossless PNG (the degraded version)
    ├── 000000_meta.json            # {degradation, param, source_path, tile_xy}
    ├── 000001_hq.png
    ├── 000001_lq.png
    ├── 000001_meta.json
    └── ...
```

`manifest.json` schema:

```json
{
  "version": 1,
  "generator": "ForgeTraining.generate_multidegradation_corpus",
  "seed": 42,
  "tile_size": 256,
  "source_dir": "/abs/path/to/hq",
  "source_sha": "9f4c…",          // SHA-256 of sorted source filename list
  "num_pairs": 500000,
  "skipped_degradations": [],
  "breakdown": {
    "noise": 124983,
    "hevc":  125042,
    "av1":   124971,
    "mpeg2": 125004
  },
  "ffmpeg": "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
  "completed_at": "2026-05-26T17:14:22Z"
}
```

Manifest writes are **atomic** (tempfile + `os.replace`) so a Ctrl-C mid-run
never leaves a half-written JSON.

## Testing

```bash
source .venv/bin/activate
python -m pytest Python/tests/ -v
```

Tests cover:

- `degradations.gaussian_noise`: shape preservation + sigma-conditioned MAD range
- `degradations.encode_hevc / encode_av1 / encode_mpeg2`: shape preservation + PSNR sanity bands
- `generate_multidegradation_corpus`: byte-identical re-runs given the same seed
- `--skip-degradation` honored

## Conventions

- Python 3.12, PEP 8, full type hints.
- `degradations.py` is pure-function (numpy in, numpy out; ffmpeg-backed helpers
  spawn subprocesses and clean up their temp files).
- ffmpeg subprocesses use the absolute path returned by `_locate_ffmpeg()` and
  always pass `-loglevel error -y` so failures surface cleanly.
- Manifest + per-pair JSON writes are atomic via `tempfile.NamedTemporaryFile`
  + `os.replace`.

## EfRLFN PyTorch → MLX converter (Phase C.3 / Task #20)

`Scripts/convert_efrlfn_to_mlx.py` translates the upstream MIT-licensed EfRLFN
PyTorch checkpoint into a safetensors file consumable by the Swift port at
`Packages/ForgeUpscaler/Sources/ForgeUpscaler/Playback/EfRLFN.swift`. See
[ADR-0006](../../Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md) for the
architecture context.

### Quick start

```bash
# 1. Set up the venv (one-time)
./setup.sh
source .venv/bin/activate

# 2. (Optional) install parity-test extra
pip install -r requirements-parity.txt

# 3. Auto-download upstream checkpoint + convert + verify parity
python Scripts/convert_efrlfn_to_mlx.py \
    --scale 4 \
    --output ../ForgeUpscaler/Sources/ForgeUpscaler/Resources/efrlfn_x4.safetensors \
    --dtype float16 \
    --verify-parity

# 4. Confirm the file loads cleanly into the MLX reference model
python Scripts/verify_swift_load.py \
    --safetensors ../ForgeUpscaler/Sources/ForgeUpscaler/Resources/efrlfn_x4.safetensors \
    --scale 4
```

### CLI flags

| Flag                | Default                                        | Notes |
| ------------------- | ---------------------------------------------- | ----- |
| `--input`, `-i`     | _(auto-download via Google Drive)_             | Path to upstream `.pt`. Omit to pull via `--cache-dir`. |
| `--output`, `-o`    | required                                       | Target `.safetensors` path. |
| `--scale`, `-s`     | `4`                                            | `2` or `4`. Upstream publishes both. |
| `--cache-dir`       | `~/.cache/efrlfn_weights`                      | Where the auto-downloader stows the `.pt`. |
| `--dtype`           | `float32`                                      | `float32` or `float16`. FP16 halves bundle size (~1.0 MB → ~0.5 MB). |
| `--verify-parity`   | off                                            | Run a numerical check vs PyTorch reference. Needs `torch`. |
| `--input-shape`     | `1,3,64,64`                                    | NCHW input shape for the parity test. |

### Upstream weights

Per the EfRLFN README, weights are hosted on Google Drive (no HuggingFace
mirror as of 2026-05-27). The converter pins the SHA-256 of each scale so a
silent upstream update is caught loudly.

| Scale | Google Drive ID                       | Pinned SHA-256        | Params  |
| ----- | ------------------------------------- | --------------------- | ------- |
| 2     | `1VeoW94hN1X-8kxGXQSyR53YzRqF1htKQ`   | `fbfd1bb3…`           | 487,010 |
| 4     | `1vJgrsz62IAMeS9i2ChDhQGO6UO1ZUXhr`   | `56a43a10…`           | 503,894 |

### Key remap

Upstream uses `nn.Sequential` for the pixel-shuffle block, so the conv's
state-dict key is `upsampler.0.weight`. The Swift port (and the MLX-Python
reference) wraps the conv in a named `PixelShuffleBlock`, so the converter
rewrites `upsampler.0.*` → `upsampler.conv.*`. All other names — `conv_1`,
`conv_2`, `block_1..block_6.{c1_r,c2_r,c3_r,c5}`, `block_N.eca.conv` — pass
through unchanged.

Conv weight layouts are transposed:
- Conv2d: PyTorch `(O, I, kH, kW)` → MLX `(O, kH, kW, I)`
- Conv1d: PyTorch `(O, I, k)` → MLX `(O, k, I)` (NLC kernel layout)

### Tests

```bash
# Unit tests — no torch required
pytest Python/tests/test_convert_efrlfn.py -v

# Parity tests — needs `pip install -r requirements-parity.txt`
pytest Python/tests/test_efrlfn_parity.py -v
```

The parity tests cover:

- Single-layer parity for `conv_1`, ECA, ERLFB, and the upsampler (the
  pixel-shuffle test is the one that catches PyTorch's NCHW `(C, r, r)`
  channel-reshape convention).
- Full forward pass at scale 2 and 4 against a synthetic state dict.
- (Optional) Full forward pass against the real upstream checkpoint when
  it's present in `$EFRLFN_CHECKPOINT_DIR`.

## See also

- `Docs/Forge-CodingPlan-v1.0.md` §B.2 / §2.4 — training-rig spec and rationale
- `Docs/Forge-CodingPlan-v1.0.md` §C.3 — EfRLFN weight-conversion spec
- `Docs/Forge-Re-Evaluation-2026-05.md` §2.1 — why NAFNet (vs. NafNet-S / Restormer)
- `Docs/ADRs/0003-nafnet-sizing-rescope.md` — rescoped target config + quality gates
- `Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md` — EfRLFN adoption rationale and quirks
- `Packages/ForgeOptimizer/Sources/ForgeOptimizer/Restoration/NAFNet.swift` — runtime
  input/output convention this corpus aligns to (NHWC, RGB uint8 → float32 [0,1])
- `Packages/ForgeUpscaler/Sources/ForgeUpscaler/Playback/EfRLFN.swift` — MLX-Swift
  port (Phase C.2) consuming the safetensors produced here
- `Forge/Tests/Corpus/scripts/fetch_corpus.sh` — pattern for ffmpeg invocation
  / Homebrew env bootstrap (reused here in `setup.sh`)
