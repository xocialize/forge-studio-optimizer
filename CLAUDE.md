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
| `Packages/ForgeOptimizer` | AI analysis + preprocessing: `Restoration/` (**NAFNet trained + wired** via `NAFNetProcessor`, B.5; v0.3 Legacy Denoiser/ArtifactRemover 256² stubs retained under `Legacy/` for the CoreML/registry path), `OpticalFlow/` (LiteFlowNet motion), `QualityRegressor/` (SigLIP2 IQA head, training pending), `ModelRegistry/` (actor + LicensePolicy + SPDX), `Benchmark/` (BenchmarkSuite + `forge-benchmark-runner` + `forge-gate-checker` + GateEvaluator + QualityMeasure), `PixelBufferBridge/` |
| `Packages/ForgeUpscaler` | SR tiers: **playback = SRVGGNetCompact-general x4** (C.4 winner, ADR-0008); export = Real-ESRGAN CoreML (ADR-0007); preview = MetalFX. `MLXTileProcessor` (NV12→BGRA + tile/whole-frame), `PlaybackTier`/`PlaybackUpscaler`, `EfRLFN*` (rejected, retained), `Temporal/` |
| `Packages/FormatBridge` | Video decode (FFmpeg) + encode (VideoToolbox: `NativeEncoderImpl` AVAssetWriter + `VideoToolboxEncoderImpl` constant-quality `VTCompressionSession`, ADR-0013). Self-contained copy of the shared Forge engine. |
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
| 0011 | **Build runnable MLX with xcodebuild** (not `swift build` — metallib); resources **per-file `.copy`** (not `.copy("Resources")` — nesting) | Accepted |
| 0012 | **Compression savings = CRF-encode vs source** (`--crf`); fixed-bitrate harness can't measure it | Accepted |
| 0013 | **VideoToolbox-first ship encoder** — HEVC default / H.264 fallback (hardware, constant-quality); AV1 (SVT) + x264 conditional/opt-in | Accepted |
| 0014 | **Revise §4 compression gate** — VMAF-targeted savings on high-bitrate sources (ship encoder), retire fixed-CRF mixed-corpus gate | Accepted |

Benchmark report: `Docs/Benchmarks/benchmark-c4-ab-v2-e06ff85.json`. Real-signage eval spec: `Docs/Benchmarks/real-signage-eval-set.md`.

## Conventions

- **NHWC** in MLX; **NCHW** in CoreML; BGR for LiteFlowNet. `@unchecked Sendable` + manual locking for GPU-state classes.
- **Weight loading** (MLX): `MLX.loadArrays` → `ModuleParameters.unflattened` → `Module.update(verify: .noUnusedKeys)`. Key remap where safetensors keys ≠ `@ModuleInfo` flatten.
- **Pixel-shuffle NHWC** must split channels `(C, r, r)` to match PyTorch `nn.PixelShuffle` (mlx-porting pitfall #7).
- **NV12 hazard**: `FFmpegDecoder` emits NV12 (biplanar YUV). Any byte-level `CVPixelBufferGetBaseAddress` reader must `ensureBGRA()` first (CoreImage) — else sheared garbage. This bug hid behind an SSIM=1.0 tautology and was only caught by *looking at output pixels*. **When validating model output, extract a frame and look.**
- **VideoToolbox must be told its colour space (BT.709)**: `VTCompressionSession` with no `ColorPrimaries`/`TransferFunction`/`YCbCrMatrix` set emits an **untagged** stream (`color_* = unknown` → players guess) *and* picks an unspecified RGB→YCbCr matrix. Fed RGB/BGRA (the NAFNet restore path: NV12 →CoreImage BGRA→ encoder), a 601-vs-709 matrix mismatch leaves **neutral colours (white) intact but drifts SATURATED ones** — a brand blue measured (39,182,229)→(52,192,226), washed-out. Diagnostic: *white preserved + saturated drift = matrix error* (a range error would shift white too). Fix: pin all three to `ITU_R_709_2` in the encoder (drift → <1 LSB; output tagged bt709). Content is HD/4K 709; follow-up = plumb the source colour space for SD/601 inputs.
- **VMAF framesync desync across timebases**: `libvmaf` pairs its two inputs by **PTS**. If test and reference live in different containers/timebases (e.g. ffv1-in-mkv @ 1/1000 vs HEVC-in-mp4 @ 1/12288), the coarser timebase's PTS rounding desyncs the pairing — motion frames compare against neighbours and VMAF collapses (a near-lossless encode measured ~70 vs its true ~93; frame-by-index PSNR was 63 dB, so frames *were* aligned by index — only the timestamp pairing was off). **Frame-lock both inputs (`settb=AVTB,setpts=N`) so pairing is by frame index.** Plain `setpts=N` is insufficient (each stream keeps its own timebase). Fixed in `QualityMeasure.vmaf`; no-op when inputs already share a pipeline.
- **fp16 reductions overflow at video resolution**: an fp16 *global* spatial mean/sum (e.g. NAFNet SCA's average-pool over H×W) overflows fp16's ~65504 ceiling at ≥540×960 → NaN → garbage output. Invisible at 128² (unit tests) and in fp32 (parity) — only a real 4K run exposed it (VMAF 3.17, #40). **Do any global pool/sum in fp32, cast back.** Lesson: validate fp16 inference at *production resolution*, not just small test tiles.
- **Parity tests** for every weight conversion (PyTorch↔MLX): single-layer max_abs < 1e-3 @ FP16, full pass < 1e-2.
- **Benchmark gates**: 5 quality/size/compression gates (realtime gates removed, ADR-0009). Throughput still measured (`fps_mean`/`realtime_factor`), not gated.
- **ADRs over inline rationale**; per-package `LICENSES.md` + `Resources/MODELS.md`.

## Open work (relocated from the Forge close-out)

- **NAFNet track (B.1→B.5) — COMPLETE** (ADR-0010). Trained on local IBM signage
  frames (1130 frames → 100k balanced noise/HEVC/AV1/MPEG-2 pairs), 300k steps,
  **best val PSNR 41.515 dB**. Converted PyTorch→MLX (`convert_nafnet_to_mlx.py`
  + oracle `nafnet_mlx.py`; parity fp32 ~2e-6 / fp16 3.35e-3 on real weights),
  vendored `ForgeOptimizer/Resources/nafnet.safetensors` (4.9 MB fp16). Wired via
  `NAFNetProcessor` (FrameProcessor; full-res, `ensureBGRA` NV12 fix); the
  `PreprocessorFactory` non-`.off` levels now use NAFNet, replacing the v0.3
  256² DnCNN+ARCNN stubs (kept under `Restoration/Legacy/`). xcodebuild test
  green. Retrain/resume: `./Scripts/run_b3_pipeline.sh` (corpus `--resume`,
  training auto-resumes from `ckpt_latest.pt`; DIV2K opt-in `USE_DIV2K=1`).
  Proprietary frames/corpus stay under gitignored `data/` — only weights ship.
  Follow-ups: vectorize the BGRA↔RGB loop (perf); tiling for 4K on 16 GB (scale).
- **Compression #40 — CAPABILITY VALIDATED; gate revised (ADR-0014, Accepted).**
  Forge optimization is proven smaller-at-quality on high-bitrate content: signage
  **62.6% @ VMAF 98.74** (CRF, ADR-0012) and **47% smaller @ guaranteed VMAF≥95**
  (VMAF-targeted, VideoToolbox HEVC, Step 1). The *original* §4 gate (fixed-CRF
  savings-vs-source, mixed corpus) is unmeasurable: the royalty-free corpus spans
  52 kbps→41 Mbps (screencapture clips already ~50–100 kbps → no headroom → can't
  "save"), and the encoder pivoted to VideoToolbox/VMAF-target (ADR-0013). Plumbing
  fixed + committed (postProcess skip for `--crf`; empty-subset N/A). **ADR-0014
  adopted**: gate = VMAF-targeted savings on a high-bitrate corpus subset, on the
  ship encoder. Remaining (#54): wire Step 0 encoder + Step 1 search into the
  benchmark + add a high-bitrate corpus tag, then flip the gate.
- **SigLIP2 NR-IQA** training + integration (retires the v0.3 KADID non-commercial scorer).
- **12-clip real-signage eval set** (IBM Think 26, local/proprietary — not committed): `Docs/Benchmarks/real-signage-eval-set.md`.
- Real-signage finding: shipped playback SR scored **97.8–99.7 VMAF** on real content incl. text → PRD VMAF≥90 met; Phase F (text-aware SR) deprioritized.

### Resume next (2026-05-31 handoff)

NAFNet track **B.1→B.5 done + shipping** (trained 41.515 dB, converted, wired,
tested). Entry-tier product story validated on real IBM signage: **SR HD→4K +13
VMAF** vs bicubic, **optimize 62.6% smaller @ 98.74 VMAF**. Encoder strategy
adopted (ADR-0013/0014); **Step 0 shipped** (native VideoToolbox constant-quality
encoder) and **Step 1 native core shipped** (all test-green). Roadmap (#48–54) —
**Step 0 ✅, Step 1 core ✅**:
1. **#49 Step 1** — native + VALIDATED END-TO-END. Core: `QualityTargetSearch`
   (sample-encode binary search for the lowest quality clearing a VMAF floor) +
   `VideoToolboxQualityTargetEncoder` (search ↔ Step-0 encoder) in FormatBridge, +
   `FFmpegVMAFScorer` (real libvmaf seam) in the runner — compose via
   `makeQualityTargetEncoder(scorer:search:)`. The **`forge-quality-target` CLI**
   runs the whole path on a real clip (decode→search→encode, bounded sample) and on
   `general-animation-01.mp4` (1080p, 5.23 Mbps) gave **63.0% smaller @ VMAF≥95**
   / **79.2% @ VMAF≥90** (`Docs/Benchmarks/step1-native-validation.md`). Found+fixed
   a real VMAF framesync-timebase bug along the way (see Conventions). **Remaining
   for full #49**: streaming full-clip final encode for long 4K masters (sample is
   bounded today). **#54** then runs it across the high-bitrate corpus vs a flat
   floor baseline for the honest cross-corpus savings number + flips the gate.
2. **#50 Step 2** — per-shot VMAF-targeted (shot-detect → per-shot search → stitch);
   reuses the same search/scorer/encoder seams; corpus now has multi-shot clips.
3. **#54** — implement ADR-0014 gate (the #49 runner pass above + high-bitrate
   corpus tag), then flip §4. **#51 Step 3** (IQA-gated NAFNet) + **#52 Step 4**
   (SVT-AV1 tier) + **#23/#15** remain on the model side.
Build reminder: **xcodebuild** for runnable MLX (ADR-0011); `swift build` only
compile-checks; FormatBridge VideoToolbox tests run under `swift test` (system
framework). ~6 build cycles/session is normal — budget for it.

**Encoding strategy (deep research delivered):** Vimeo ≈ per-title **x264 ~CRF 20**
High@5.2, adaptive B-frames, ~2–3 s GOP, **no SR**
(`Docs/Benchmarks/vimeo-method-analysis.md`). Research report adopted →
`Docs/Research/forge-studio-encoding-strategy-v2.md`: ship **VideoToolbox HEVC +
VMAF-targeted per-title/per-shot** rate control (ADR-0013), beat Vimeo via NAFNet
(degraded input) + HD→4K SR + opt-in AV1. The Step 0→6 roadmap above is the
productization of that report.

## Provenance

Clean copy from `xocialize-code/Forge` (`feature/forge-2026-q2-refresh`), 2026-05-29.
Full history lives in Forge. The realtime app (ForgeAlpha, MediaLibrary, app shell)
stays in Forge. FormatBridge + FFmpegXC are a self-contained copy of the shared
video engine; extracting a shared `format-bridge` package is a future cleanup.

## Skills worth loading

- `anthropic-skills:mlx-porting` — every model port / weight-conversion task.
