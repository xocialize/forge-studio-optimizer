# forge-studio-optimizer — CLAUDE.md

## Project Overview

The **non-realtime, quality-first** AI video stack for the **ForgeStudio** umbrella
(MVS Collective). Relocated from the `xocialize-code/Forge` monorepo on 2026-05-29
so quality work evolves independently of the realtime Forge app.

**Owner**: Dustin / MVS Collective
**Platform**: macOS 15+ (Apple Silicon arm64 only)
**Stack**: MLX-Swift (≥0.31.2) + CoreML; FFmpeg decode + VideoToolbox encode
**No realtime requirement** — ADR-0009 dropped it (it's a separate-project concern).
**PRD**: `Docs/ForgeStudio-PRD-v0.1.md` — forward-looking *reference*, NOT authoritative; the code is ahead of it.

## Packages & dependency stack

```
ForgeOptimizer ──→ ForgeUpscaler ──→ FormatBridge ──→ FFmpegXC
       └──────────→ FormatBridge ──↗
   all ──→ mlx-swift (remote, 0.31.2 ..< 0.32.0 → resolves 0.31.3)
```

| Package | Role |
|---|---|
| `Packages/ForgeOptimizer` | AI analysis + preprocessing: `Restoration/` (NAFNet — port done, weights pending B.3; v0.3 Legacy Denoiser/ArtifactRemover are **256²-resize STUBS**), `OpticalFlow/` (LiteFlowNet motion), `QualityRegressor/` (SigLIP2 IQA head, training pending), `ModelRegistry/` (actor + LicensePolicy + SPDX), `Benchmark/` (BenchmarkSuite + `forge-benchmark-runner` + `forge-gate-checker` + GateEvaluator + QualityMeasure), `PixelBufferBridge/` |
| `Packages/ForgeUpscaler` | SR tiers: **playback = SRVGGNetCompact-general x4** (C.4 winner, ADR-0008); export = Real-ESRGAN CoreML (ADR-0007); preview = MetalFX. `MLXTileProcessor` (NV12→BGRA + tile/whole-frame), `PlaybackTier`/`PlaybackUpscaler`, `EfRLFN*` (rejected, retained), `Temporal/` |
| `Packages/FormatBridge` | Video decode (FFmpeg) + encode (VideoToolbox). Self-contained copy of the shared Forge engine. |
| `Packages/FFmpegXC` | Vendored LGPL-safe FFmpeg 7.1.1 static libs. `.a` files gitignored — `./build.sh` rebuilds. |
| `Packages/ForgeTraining` | Off-device Python rig (never shipped). B.2 corpus generator (`--resume`) + B.3 NAFNet trainer (`Scripts/train_nafnet.{py,sh}`, restart-friendly — see `TRAINING.md`). |
| `Tests/Corpus` | 30-clip royalty-free benchmark corpus. `manifest.json` + `scripts/` tracked; `clips/` gitignored (re-fetch). |

## Build

```bash
# FFmpegXC static libs (fresh clone — gitignored)
cd Packages/FFmpegXC && ./build.sh

# ⚠️ ANY runnable MLX-inference binary MUST be built with xcodebuild, NOT
# `swift build`. swift build compiles the Swift but never builds mlx-swift's
# Metal kernels into default.metallib → the binary fails at runtime with
# "Failed to load the default metallib". xcodebuild compiles the metallib
# (into mlx-swift_Cmlx.bundle, sibling to the binary) and bundles per-package
# resources (model weights) correctly. swift build is fine ONLY for non-MLX
# compile checks. (See ADR-0011.)
cd Packages/ForgeOptimizer && xcodebuild build -scheme forge-benchmark-runner \
    -configuration Release -destination 'platform=macOS' -derivedDataPath .xcode-build
RUNNER=.xcode-build/Build/Products/Release/forge-benchmark-runner

# CLI tests (Xcode needed for MLX-Metal suites: NAFNetTests, EfRLFNTests, LiteFlowNetTests)
xcodebuild test -scheme ForgeOptimizer-Package -destination 'platform=macOS'

# Corpus (Homebrew ffmpeg-full for drawtext + libvmaf)
cd Tests/Corpus && ./scripts/fetch_corpus.sh

# Benchmark
$RUNNER --corpus ../../Tests/Corpus/manifest.json \
    --upscaler-pass-only --playback-backend all --playback-scale 4 --output report.json
```

## ADRs (Docs/ADRs)

| # | Subject | Status |
|---|---|---|
| 0001–0002 | Refresh kickoff; dev-vs-runtime ffmpeg LGPL split | Accepted |
| 0003 | NAFNet sizing (width=24, [1,1,1,1] default, **2.54M params** — verified vs Swift port; the "~1.4M" prose was an under-estimate) | Accepted |
| 0005 | SigLIP2 lazy-download (~400 MB) | Accepted |
| 0006 | EfRLFN adopted provisionally | Accepted (default **reversed** by 0008; throughput half dropped by 0009) |
| 0007 | Real-ESRGAN CoreML export tier | Accepted |
| 0008 | **Phase C.4 verdict — ship SRVGGNet-general, reject EfRLFN** (−26.8 VMAF) | Accepted |
| 0009 | **Drop realtime requirements** (separate-project concern); 2 throughput gates removed | Accepted |
| 0010 | **NAFNet B.3 training data** — domain IBM signage frames (not DIV2K); proprietary handling (frames/corpus never committed, only weights ship) | Accepted |

Benchmark report: `Docs/Benchmarks/benchmark-c4-ab-v2-e06ff85.json`. Real-signage eval spec: `Docs/Benchmarks/real-signage-eval-set.md`.

## Conventions

- **NHWC** in MLX; **NCHW** in CoreML; BGR for LiteFlowNet. `@unchecked Sendable` + manual locking for GPU-state classes.
- **Weight loading** (MLX): `MLX.loadArrays` → `ModuleParameters.unflattened` → `Module.update(verify: .noUnusedKeys)`. Key remap where safetensors keys ≠ `@ModuleInfo` flatten.
- **Pixel-shuffle NHWC** must split channels `(C, r, r)` to match PyTorch `nn.PixelShuffle` (mlx-porting pitfall #7).
- **NV12 hazard**: `FFmpegDecoder` emits NV12 (biplanar YUV). Any byte-level `CVPixelBufferGetBaseAddress` reader must `ensureBGRA()` first (CoreImage) — else sheared garbage. This bug hid behind an SSIM=1.0 tautology and was only caught by *looking at output pixels*. **When validating model output, extract a frame and look.**
- **Parity tests** for every weight conversion (PyTorch↔MLX): single-layer max_abs < 1e-3 @ FP16, full pass < 1e-2.
- **Benchmark gates**: 5 quality/size/compression gates (realtime gates removed, ADR-0009). Throughput still measured (`fps_mean`/`realtime_factor`), not gated.
- **ADRs over inline rationale**; per-package `LICENSES.md` + `Resources/MODELS.md`.

## Open work (relocated from the Forge close-out)

- **NAFNet training track (B.3→B.5)**: B.3 **RUNNING** (ADR-0010). HQ source =
  local IBM signage frames (1130 frames from 23 masters), corpus = 100k balanced
  degraded pairs (~25% each noise/HEVC/AV1/MPEG-2), NAFNet 2.54M on MPS @
  ~3.3 it/s (~25 h for 300k steps, auto-resume). Detached + restart-friendly:
  re-run `./Scripts/run_b3_pipeline.sh` to resume any interrupted stage
  (corpus `--resume`, training resumes from `ckpt_latest.pt`). DIV2K is now
  opt-in (`USE_DIV2K=1`). Proprietary frames/corpus live under gitignored
  `data/` — never committed; only weights ship. Next: B.4 convert (PyTorch→MLX)
  → B.5 wire (replaces v0.3 256² stubs) → unblocks the #40 compression gates.
  Runbook: `ForgeTraining/TRAINING.md`.
- **B.4 converter — READY + validated** (`Scripts/convert_nafnet_to_mlx.py` +
  MLX-Python oracle `Python/models/nafnet_mlx.py`). PyTorch→MLX key remap
  (`encoders.i.j`→`encoders.i.blocks.layers.j`, `downs.i`→`encoders.i.down`,
  `ups.i.0`→`decoders.i.upConv`, `norm{1,2}`→`norm{1,2}.norm`), conv-layout +
  depthwise + beta/gamma NHWC transpose. Parity vs PyTorch: **fp32 ~2e-6, fp16
  ~6.8e-4** (4.9 MB fp16, < 12 MB gate); 12 tests green. Final conversion is a
  one-shot once B.3 lands a best checkpoint:
  `python Scripts/convert_nafnet_to_mlx.py -i runs/nafnet-b3/nafnet_best.pt
  -o ../ForgeOptimizer/Sources/ForgeOptimizer/Resources/nafnet.safetensors
  --dtype float16 --verify-parity`.
- **Compression-gate validation** (§4 ≥35% @Balanced, VMAF≥90, ≥55% signage @Maximum) — **blocked on B.5** (can't validate on the v0.3 stub).
- **SigLIP2 NR-IQA** training + integration (retires the v0.3 KADID non-commercial scorer).
- **12-clip real-signage eval set** (IBM Think 26, local/proprietary — not committed): `Docs/Benchmarks/real-signage-eval-set.md`.
- Real-signage finding: shipped playback SR scored **97.8–99.7 VMAF** on real content incl. text → PRD VMAF≥90 met; Phase F (text-aware SR) deprioritized.

## Provenance

Clean copy from `xocialize-code/Forge` (`feature/forge-2026-q2-refresh`), 2026-05-29.
Full history lives in Forge. The realtime app (ForgeAlpha, MediaLibrary, app shell)
stays in Forge. FormatBridge + FFmpegXC are a self-contained copy of the shared
video engine; extracting a shared `format-bridge` package is a future cleanup.

## Skills worth loading

- `anthropic-skills:mlx-porting` — every model port / weight-conversion task.
