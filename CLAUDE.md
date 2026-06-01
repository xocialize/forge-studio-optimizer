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
| 0014 | **Revise §4 compression gate** — VMAF-targeted vs-flat savings on high-bitrate sources; **implemented (#54)**: threshold calibrated **≥15%** (measured 16.6%, PASS), fixed-CRF gates retired from GateEvaluator (v1.1, 3 gates), gated by `Tools/quality_target_gate.py` | Accepted |
| 0015 | **Per-shot deferred on VideoToolbox** — capped per-shot ties per-title (~0%); VT constant-quality already adapts per-frame. Don't ship; revisit only with fixed-CRF x264 (#53) | Accepted |
| 0016 | **Step 3 IQA gate = scoped "restoration-pays" (#56)** — v2 SigLIP2 head (data-mix iteration: frame-level + multi-res + DISTS labels) scores low where NAFNet pays (encoded/photographic), high on flat-vector (045/094, where orig≈restored = a wash). Ship default-on, threshold ~0.78; revisit fine-tuning post-ImageBridge | Accepted |
| 0017 | **AV1 tier via SVT-AV1 subprocess first (#52)** — no HW AV1 encode on Apple Silicon (VT −12908) + FFmpegXC has no AV1 encoder, so Phase A = `forge-quality-target --codec av1` (VMAF-targeted SVT-AV1 CRF search + `--film-grain`, via ffmpeg). AV1 ~44–53% < HEVC on signage. In-process FFmpegXC+SVT-AV1 = Phase B (end-polish) | Accepted |
| 0018 | **Steps 5/6 deferred — AV1 is the premium path (#53)** — A/B (graphics @ VMAF95, vs our real VT-HEVC ~0.37 Mbps): AV1 ~57% / x265-veryslow ~41% smaller; x264 *larger*. Licensed x264/x265 premium NOT worth the GPL+patent spend (AV1 covers premium, royalty-free). Convex-hull marginal for single-rendition signage. **#59 resolved: the "74% VT-HEVC" alarm was an ffmpeg `-q:v` wrapper artifact — our actual encoder is healthy (~41% behind x265, normal HW tradeoff)** | Accepted |

Benchmark report: `Docs/Benchmarks/benchmark-c4-ab-v2-e06ff85.json`. Real-signage eval spec: `Docs/Benchmarks/real-signage-eval-set.md`.

## Conventions

- **NHWC** in MLX; **NCHW** in CoreML; BGR for LiteFlowNet. `@unchecked Sendable` + manual locking for GPU-state classes.
- **Weight loading** (MLX): `MLX.loadArrays` → `ModuleParameters.unflattened` → `Module.update(verify: .noUnusedKeys)`. Key remap where safetensors keys ≠ `@ModuleInfo` flatten.
- **Pixel-shuffle NHWC** must split channels `(C, r, r)` to match PyTorch `nn.PixelShuffle` (mlx-porting pitfall #7).
- **NV12 hazard**: `FFmpegDecoder` emits NV12 (biplanar YUV). Any byte-level `CVPixelBufferGetBaseAddress` reader must `ensureBGRA()` first (CoreImage) — else sheared garbage. This bug hid behind an SSIM=1.0 tautology and was only caught by *looking at output pixels*. **When validating model output, extract a frame and look.**
- **VideoToolbox must be told its colour space (BT.709)**: `VTCompressionSession` with no `ColorPrimaries`/`TransferFunction`/`YCbCrMatrix` set emits an **untagged** stream (`color_* = unknown` → players guess) *and* picks an unspecified RGB→YCbCr matrix. Fed RGB/BGRA (the NAFNet restore path: NV12 →CoreImage BGRA→ encoder), a 601-vs-709 matrix mismatch leaves **neutral colours (white) intact but drifts SATURATED ones** — a brand blue measured (39,182,229)→(52,192,226), washed-out. Diagnostic: *white preserved + saturated drift = matrix error* (a range error would shift white too). Fix: pin all three to `ITU_R_709_2` in the encoder (drift → <1 LSB; output tagged bt709). Content is HD/4K 709; follow-up = plumb the source colour space for SD/601 inputs.
- **VMAF reference must be frame-exact + the harness can lie**: a quality search is only as honest as its reference. Two bugs found (#55): (1) building the reference by repacking decoded NV12 → rawvideo → ffv1 corrupted it ~3–6 VMAF pts; (2) selecting a frame range with `select=...,setpts=N` / `trim=...,setpts=N` **collapsed the output to ~2 frames** (`setpts=N` renumbers PTS into near-zero gaps the muxer drops). Correct recipe: `ffmpeg -i src -vf "trim=start_frame=S:end_frame=E"` (NO setpts) tagged bt709/tv → lossless ffv1; alignment is handled later by the framesync filter. **Always cross-check the pipeline's VMAF against an independent ffmpeg measurement** — that's how this was caught (encoder was correct at 99.84; the *reference* was wrong). Step 1's 63% @ VMAF≥95 holds after the fix (pipeline == independent: 98.55 == 98.55).
- **A hand-crafted artifact proxy ≠ perceptual quality (Step 3, #51)**: the IQA-gate's interim `BlockinessQualityScorer` (8×8 DCT-grid energy) passed synthetic unit tests but, on real clips, **scored the worst Snowflake bad file (4K@1.9 Mbps, ringing-heavy) 0.98 "clean" → would skip restoration**, and false-positived on clean CGI. Our signage degrades as **ringing around sharp edges, not grid-aligned blocking** — blockiness can't see it. The IQA gate **requires the learned SigLIP2 NR-IQA head (#23)**; the heuristic is a baseline only (catches classic DVD/MPEG-2 blocking). **Validate any quality signal on real clean AND real degraded content before trusting it** (same family as the VMAF-reference catch). `forge-quality-target --score` to inspect.
- **Per-shot doesn't pay on VideoToolbox (ADR-0015)**: naive per-shot LOSES (−18 to −26%: IDR/warmup overhead + over-serving hard shots); **capped** per-shot (shot quality ≤ per-title quality, ship `min(per-shot, per-title)`) only TIES (~0%) — because VT constant-quality already adapts bits per-frame, so easy shots are already cheap and the cap bounds the upside. The research's per-shot win is vs a fixed-CRF baseline; ours is VBR. Don't ship per-shot for VT; revisit only with fixed-CRF x264 (#53).
- **VMAF framesync desync across timebases**: `libvmaf` pairs its two inputs by **PTS**. If test and reference live in different containers/timebases (e.g. ffv1-in-mkv @ 1/1000 vs HEVC-in-mp4 @ 1/12288), the coarser timebase's PTS rounding desyncs the pairing — motion frames compare against neighbours and VMAF collapses (a near-lossless encode measured ~70 vs its true ~93; frame-by-index PSNR was 63 dB, so frames *were* aligned by index — only the timestamp pairing was off). **Frame-lock both inputs (`settb=AVTB,setpts=N`) so pairing is by frame index.** Plain `setpts=N` is insufficient (each stream keeps its own timebase). Fixed in `QualityMeasure.vmaf`; no-op when inputs already share a pipeline.
- **fp16 reductions overflow at video resolution**: an fp16 *global* spatial mean/sum (e.g. NAFNet SCA's average-pool over H×W) overflows fp16's ~65504 ceiling at ≥540×960 → NaN → garbage output. Invisible at 128² (unit tests) and in fp32 (parity) — only a real 4K run exposed it (VMAF 3.17, #40). **Do any global pool/sum in fp32, cast back.** Lesson: validate fp16 inference at *production resolution*, not just small test tiles.
- **Parity tests** for every weight conversion (PyTorch↔MLX): single-layer max_abs < 1e-3 @ FP16, full pass < 1e-2. **A port "passes" only against REAL weights, not zeros** (#57): #27's SigLIP2 `loadWeights` shipped "complete" with shape-only tests against zeros and was silently broken three ways on the real mlx-community 8-bit checkpoint — (a) doubled `vision_model.vision_model.` prefix half-stripped → keys unmatched → backbone ran on **random init**; (b) 8-bit Linears are **packed U32 + sibling `.scales`/`.biases`** (group_size=64, bits=8), not fp — must `dequantized(w,scales,biases,64,8)` on load, not load the packed stem; (c) the conv `patch_embedding` is **already NHWC** in the MLX checkpoint (no NCHW→NHWC transpose). Fixed + parity-validated (cosine **0.9999** vs PyTorch FP) → quant gap negligible. **MLX `dequantized`/`loadArrays` do NOT honor the scoped CPU pin** (`withDefaultDevice(.cpu)`) → real-weight MLX tests must run via **`xcodebuild test -scheme ForgeOptimizer-Package`**, not `swift test` (lazy shape-only tests survive `swift test`; anything that evaluates a quantized op needs the staged metallib). Ref generator: `Scripts/gen_siglip2_parity_ref.py`; test: `SigLIP2ParityTests`.
- **AVAssetWriter interleave deadlock — defer, don't block (#32)**: a single-threaded decode→encode loop that pushes packets in demuxer order will **deadlock** when one track races ahead — the writer sets that input `isReadyForMoreMediaData = false` until the other track catches up, but the only way to advance the other track is to push it, which a caller block-spinning inside `appendVideoFrame` can't reach (the hybrid WebM/MKV+audio→MP4 path stalled ~2/3 of the time, masked as a "flaky test"). Fix: when an input isn't ready, **queue the buffer and return** (retaining a `CVPixelBufferPool` buffer is safe — the pool won't recycle it, so no copy) so the loop pushes the other track; and at `finish()` **mark each track finished as its queue empties** (a track at EOS otherwise holds the other not-ready). `NativeEncoderImpl`, validated 15/15 + suite 53/53.
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
  fixed + committed (postProcess skip for `--crf`; empty-subset N/A). **#54 DONE**:
  gate = VMAF-targeted **vs-flat** savings on the ≥8 Mbps subset (sports-01/02,
  talkinghead-01), threshold **≥15%** (measured **16.6%**, PASS; calibrated from 30%
  — the vs-flat metric is ~the literature's 20% per-title win, smaller than the
  63%-vs-source headline). Fixed-CRF gates retired from GateEvaluator (v1.1).
  Gated by `Tools/quality_target_gate.py` (uses `forge-quality-target --fixed/--json`),
  not the optimizer benchmark. `Docs/Benchmarks/adr0014-gate-measurement.md`.
- **SigLIP2 NR-IQA** training + integration (retires the v0.3 KADID non-commercial scorer).
- **12-clip real-signage eval set** (IBM Think 26, local/proprietary — not committed): `Docs/Benchmarks/real-signage-eval-set.md`.
- Real-signage finding: shipped playback SR scored **97.8–99.7 VMAF** on real content incl. text → PRD VMAF≥90 met; Phase F (text-aware SR) deprioritized.

### Resume next (2026-06-01 handoff)

The **VideoToolbox compression story (Steps 0/1) + the §4 gate ship and are validated.**
Steps 0/1 = **63% @ VMAF≥95 / 79% @ ≥90** vs source (cross-checked); Step 2 deferred
(ADR-0015, capped per-shot ties); #54 gate PASS (16.6% vs-flat ≥15%). NAFNet B.1→B.5 ships.

**Step 3 (#51) — IQA gate: decided + de-risked, one wiring stretch left.**
- **#56 ✅ (ADR-0016)** — the data-mix iteration resolved the v1 gate gap. v2 head
  (`generate_iqa_dataset.py` reworked: **frame-level** degrade + **multi-res** + heavier
  params + resumable; even-dims bug fixed) → `data/iqa_ds2` (4197 tiles) → **val SRCC 0.902 /
  PLCC 0.956**. Real-frame eval reframed the 045 "miss" as **correct**: it's a working
  **"does-restoration-pay" gate** — low where NAFNet pays (crush 0.66, dvd4 0.58), high on
  flat-vector 045/094 where NAFNet is a **wash** (orig 0.970 → restored 0.968; 64-patch min
  still ≈ clean). Threshold ~0.78. **Decision: ship scoped for signage; revisit fine-tuning
  post-ImageBridge.** (`step3-iqa-gate-findings.md` Update 2026-06-01b + ADR-0016.)
- **#57 ✅** — fixing #27's SigLIP2 backbone loader was a prerequisite (it was broken three
  ways on the real 8-bit checkpoint; see Conventions). Fixed + **parity-validated cosine
  0.9999** vs PyTorch FP → quant gap negligible, head + ~0.78 threshold transfer to Swift.
- **▶ REMAINING (the gate wiring, now unblocked):** (1) load `data/iqa_head2/
  siglip2_iqa_head.safetensors` into `SigLIP2_IQA` + ship to `ForgeOptimizer/.../Resources/`
  (head keys fc1/fc2 match); (2) a `NoReferenceQualityScoring` adapter — CVPixelBuffer → 224
  patches → NHWC MLXArray (mean/std 0.5) → `SigLIP2QualityScorer.score()` → patch-mean Float
  (`poolerOutput` is already mean-pool); (3) verify clean>degraded ranking + the ~0.78 point
  hold in Swift on `data/iqa_eval_frames/`; (4) flip `makeGatedChain` default-on (replace the
  `BlockinessQualityScorer` baseline); (5) run via **xcodebuild**. Eval frames + v2 head live
  OFF-REPO under `Packages/ForgeTraining/data/` (gitignored; weights ship per ADR-0010).

Other remaining: close **#33** (stale — superseded by ADR-0013; the benchmark's inlined
AVAssetWriter is fine, "migrate to NativeEncoder" no longer applies — decide close/re-scope);
**#52** Step 4 (SVT-AV1 opt-in — needs SVT-AV1 vendored), #53 (x264/convex-hull), #15 (PocketDVDNet),
#23 (QualiCLIP+ Plan-B / post-ImageBridge head fine-tune).

**Validate-on-REAL-content catches keep paying off** (now 5×): VMAF reference corruption (#55),
BT.601-vs-709 colour drift, stale manifest path, blockiness mis-gate, and this session's two —
the AVAssetWriter interleave **deadlock** (#32, a real bug masked as a flaky test) and #27's
**broken-against-real-weights** SigLIP2 loader (#57). All distilled into Conventions.

Build reminder: **xcodebuild** for runnable MLX (ADR-0011); `swift build` only
compile-checks; FormatBridge/forge-quality-target VMAF+per-shot paths run under `swift
build` (no MLX), but `--restore` (NAFNet) needs xcodebuild. ~6 build cycles/session normal.

**Encoding strategy (research adopted, `forge-studio-encoding-strategy-v2.md`):** Vimeo ≈
per-title x264 ~CRF 20, no SR. Forge ships **VideoToolbox HEVC + VMAF-targeted per-title**
(per-shot doesn't pay on VT), beats Vimeo via NAFNet (degraded input) + HD→4K SR + opt-in AV1.

**ImageBridge** (post-video static-image sibling package) noted in memory
(`imagebridge-seed.md`): reuses our optimization unchanged; flags (ADR-number placeholders,
alpha=separate instances, tiling, licensing) captured. Do NOT let it derail video.

## Provenance

Clean copy from `xocialize-code/Forge` (`feature/forge-2026-q2-refresh`), 2026-05-29.
Full history lives in Forge. The realtime app (ForgeAlpha, MediaLibrary, app shell)
stays in Forge. FormatBridge + FFmpegXC are a self-contained copy of the shared
video engine; extracting a shared `format-bridge` package is a future cleanup.

## Skills worth loading

- `anthropic-skills:mlx-porting` — every model port / weight-conversion task.
