# Forge Pipelines Coding Plan v1.0

**Status**: Implementation-Ready
**Owner**: Dustin / MVS Collective
**Created**: 2026-05-26
**Basis**: Forge PRD v0.3 + ForgeUpscaler PRD + 45-Day Re-Evaluation Report (May 2026)
**Target branch root**: `feature/forge-2026-q2-refresh`

---

## 0. Context for the Implementer

The 45-day re-evaluation identified five concrete changes to the Forge pipeline stack that meaningfully improve the speed/quality/size Pareto frontier. This plan converts those findings into an executable implementation sequence.

**What is NOT changing:**

- The two-pass architecture (analysis → preprocess+encode)
- The CVPixelBuffer handoff at `FFmpegDecoder` → `ForgeOptimizer` → `NativeEncoder`
- The `ForgeOptimizer` SPM package boundary (shared between Forge and Marquee Studio Pro)
- The Apple Vision saliency path (`VNGenerateAttentionBasedSaliencyImageRequest` stays; ViSAGE is watch-list only)
- The LiteFlowNet → CoreML effort (separate, near-complete workstream)
- The VideoToolbox encoder path or FFmpeg decoder configuration

**What IS changing:**

1. **ForgeUpscaler playback tier**: `SRVGGNetCompact` → `SPANV2` (NTIRE 2026 ESR winner)
2. **ForgeOptimizer restoration**: `DnCNN-color` + `DnCNN-gray` + `ARCNN` → single `NAFNet` (3-in-1 multi-degradation model)
3. **ForgeOptimizer QualityRegressor**: bespoke CNN → SigLIP2 NR-IQA head
4. **ForgeUpscaler export tier**: in-house RRDBNet port → adopt existing Real-ESRGAN MLX port (themindstudio/RealESRGAN-x4plus-mlx, BSD-3-Clause)
5. **MLX baseline**: pin `mlx-swift` against `mlx ≥ 0.31.2` (3D-conv speedup matters for any multi-frame path)

**Conventions reminder (from established MVS Collective practice):**

- Xcode workspace at top level; `Package.swift` is a dependency manifest only
- Build tool is `xcodebuild`; CI runs `xcodebuild test`
- Apple Silicon arm64-only; no x86 fallbacks anywhere
- No Python at runtime; Python lives in `Packages/ForgeTraining/` and runs off-device only
- All model-loading code carries `weightLicense: SPDXLicense` and goes through `LicensePolicy` (replicate the DubKit pattern)
- Do NOT add SwiftPM-CLI Metal-limitation caveats anywhere

---

## 1. Repository Layout

```
Forge.xcworkspace/
├── Forge/                              # Main macOS app target
├── ForgeServer/                        # Embedded HTTP server (unchanged)
├── ForgeTV/                            # tvOS companion (touched in C5)
└── Packages/
    ├── ForgeCore/                      # FFmpegDecoder, NativeEncoder, PixelBufferPool (unchanged)
    ├── ForgeOptimizer/                 # Two-pass AI pipeline — HEAVILY TOUCHED
    │   ├── Sources/ForgeOptimizer/
    │   │   ├── Analysis/               # Saliency, motion, quality scoring
    │   │   ├── Restoration/            # NAFNet (NEW); DnCNN/ARCNN moved to /Legacy
    │   │   ├── QualityRegressor/       # SigLIP2 head (NEW); CNN moved to /Legacy
    │   │   ├── ModelChain/
    │   │   ├── ModelRegistry/          # NEW — Phase A.3
    │   │   └── PixelBufferBridge/
    │   ├── Resources/Models/           # .mlpackage bundle (contents changing)
    │   └── Tests/
    ├── ForgeUpscaler/                  # SCAFFOLD per existing PRD; THIS PR FLESHES OUT
    │   ├── Sources/ForgeUpscaler/
    │   │   ├── Playback/               # SPANV2 (NEW)
    │   │   ├── Export/                 # Real-ESRGAN MLX wrapper (NEW); OSEDiff stub (NEW)
    │   │   ├── Signage/                # Text-aware fine-tune wrapper (Phase F)
    │   │   └── TemporalBlender/        # Flow-guided blending (unchanged from PRD)
    │   └── Tests/
    └── ForgeTraining/                  # OFFLINE-ONLY; never shipped, never linked at runtime
        ├── Python/                     # NAFNet, SPANV2, SigLIP2-IQA training
        └── Scripts/                    # Weight conversion PyTorch → MLX → .mlpackage
```

---

## 2. Pre-Flight Checklist

Complete every box before touching model code.

### 2.1 Dependency pinning

- [ ] Bump `mlx-swift` to the release matching `mlx ≥ 0.31.2`
- [ ] Verify no custom `QuantizedLinear` subclasses break (the `bias` parameter is now optional — breaking change)
- [ ] Confirm `mx.conv3d` speedup is active (sanity test: run a 3D-conv micro-benchmark in `ForgeOptimizer/Tests/`)
- [ ] All ForgeOptimizer model-loading protocols expose `weightLicense: SPDXLicense`
- [ ] `LicensePolicy` enforced on the new model registry (commercial gate at load time)

### 2.2 Benchmark harness

- [ ] `ForgeOptimizer/Tests/BenchmarkSuite.swift` measures:
  - **Speed**: ms/frame at 1080p (and 4K for upscaler) on M4 Pro and M5 Pro
  - **Quality**: VMAF, PSNR, SSIM, LPIPS vs ground truth
  - **Memory**: peak unified-memory residency per `OptimizationLevel`
  - **Bundle**: total `.mlpackage` bytes in `Resources/Models/`
- [ ] Baselines captured for current 6-model pipeline: `Forge/Documentation/Benchmarks/baseline-v0.3.json`

### 2.3 Test corpus

- [ ] 30-clip evaluation corpus, equally split:
  - General (10): film, animation, sports, talking-head, screen-capture
  - Signage (10): static/dynamic logos, text overlays, transitions
  - Legacy (10): DVD MPEG-2 rips, broadcast captures, interlaced sources
- [ ] Synthetic degradation pipeline for paired HQ/LQ training data

### 2.4 Training rig

- [ ] DIV2K + Flickr2K downloaded on M5 Pro home lab (~15 GB)
- [ ] Custom signage corpus indexed
- [ ] DVD restoration corpus indexed (MPEG-2 + 4:2:0 chroma subsampling + interlacing degradations)

---

## 3. Implementation Phases

Phases run in roughly the order shown. **B and C can run in parallel after A completes.** Phases D, E, F follow the dependencies in §3.5.

### Phase A — Foundation (Week 1, ~5 days)

#### A.1 MLX version bump

- Bump `Package.swift` MLX-Swift dependency
- Run full ForgeOptimizer test suite; fix any breakage from QuantizedLinear bias change
- Verify the 3D-conv speedup is real on the existing DnCNN path
- **Acceptance**: All existing tests pass; benchmark harness shows ≥1.0× throughput on the legacy pipeline (no regressions)

#### A.2 Benchmark harness

- Implement `BenchmarkSuite` per §2.2
- Capture baselines for the current 6-model pipeline
- Output: two JSON files in `Forge/Documentation/Benchmarks/`:
  - `baseline-v0.3-mlx-0.30.x.json`
  - `baseline-v0.3-mlx-0.31.2.json`
- **Acceptance**: JSON checked in; harness reproducible from a single `xcodebuild test` invocation

#### A.3 Model registry

- Create `ModelRegistry` actor in `Packages/ForgeOptimizer/Sources/ForgeOptimizer/ModelRegistry/`
- Responsibilities:
  - Lazy-load `.mlpackage` resources from bundle
  - Track SPDX license per model in a `ModelManifest` struct
  - Enforce `LicensePolicy` at load time (refuse load if not commercial-compatible)
  - Support A/B testing: same protocol, multiple implementations registered under a `ModelRole` enum (e.g. `.restoration`, `.qualityRegressor`, `.playbackUpscaler`)
- **Acceptance**: Existing DnCNN/ESPCN/ARCNN/QualityRegressor all load through the registry; nothing observable changes for callers

**Phase A gate: STOP and report baseline benchmark JSON to Dustin before starting B or C.**

### Phase B — ForgeOptimizer Restoration Consolidation (Weeks 2-4)

**Goal**: Replace `DnCNN-color` + `DnCNN-gray` + `ARCNN` with a single NAFNet handling joint denoise + artifact removal across Gaussian noise, HEVC artifacts, AV1 artifacts, and MPEG-2 artifacts.

#### B.1 NAFNet MLX-Swift implementation

- Port `megvii-research/NAFNet` (MIT license) to MLX-Swift
- Configuration: width=32, blocks=8 (per re-eval — ~1.1 GMACs, ≤6 MB target)
- Reference: `github.com/megvii-research/NAFNet/blob/main/basicsr/models/archs/NAFNet_arch.py`
- Pure conv + element-wise + LayerNorm + SimpleGate; no exotic ops
- File: `Packages/ForgeOptimizer/Sources/ForgeOptimizer/Restoration/NAFNet.swift`
- **Acceptance**: Forward pass on a 256×256 tile matches PyTorch reference within FP16 tolerance (≤1e-3 max absolute error); unit tests in `NAFNetTests.swift`

#### B.2 Training corpus generation (Python)

- Script: `Packages/ForgeTraining/Python/generate_multidegradation_corpus.py`
- Per-clip random degradations:
  - Gaussian noise (σ ∈ [5, 50])
  - HEVC compression (CRF ∈ [22, 35], two-pass via FFmpeg)
  - AV1 compression (CRF ∈ [25, 40] via libaom-av1)
  - MPEG-2 compression (bitrate ∈ [2, 8] Mbps, IBP structure)
- Output: paired HQ/LQ tiles at 256×256
- Target volume: ≥500K tile pairs
- **Acceptance**: Visual spot-check on 50 random pairs confirms degradation realism

#### B.3 NAFNet training (Python, M5 Pro)

- Train width-32 8-block NAFNet on the multi-degradation corpus
- Hardware: PyTorch MPS on M5 Pro home lab; batch 16 at 256×256
- Loss: L1 + 0.1×SSIM + 0.05×LPIPS
- Schedule: 300K iterations, cosine LR 2e-4 → 1e-6
- Expected wall time: ~4 days
- **Acceptance**:
  - PSNR ≥35 dB on held-out SIDD subset (joint noise)
  - PSNR within 0.3 dB of dedicated ARCNN on HEVC-only subset
  - PSNR within 0.5 dB on MPEG-2 subset (no prior baseline; establish here)

#### B.4 Weight conversion

- Script: `Packages/ForgeTraining/Scripts/convert_nafnet_to_mlx.py`
- PyTorch state dict → MLX `.safetensors` → `.mlpackage` (CoreML wrapper for bundle loading)
- Target size: ≤6 MB (vs ~9 MB combined for DnCNN-color + DnCNN-gray + ARCNN)
- **Acceptance**: Loaded MLX weights produce output matching PyTorch within FP16 tolerance

#### B.5 ModelChain integration

- Replace DnCNN-color, DnCNN-gray, ARCNN nodes with a single NAFNet node
- SoftROIFilter (CIColorKernel) stays — applied between NAFNet output and optional ESPCN super-resolution
- Update `OptimizationLevel.enabledProcessors`:
  - `.light` → NAFNet (light-mode hyperparameters)
  - `.balanced` → NAFNet + SoftROIFilter
  - `.aggressive` → NAFNet + SoftROIFilter + ESPCN2x
  - `.maximum` → NAFNet + SoftROIFilter + ESPCN4x
- Move legacy `DnCNN.swift` and `ARCNN.swift` to `Restoration/Legacy/`; keep behind a feature flag for one release cycle
- **Acceptance**:
  - VMAF ≥90 at Balanced on the 30-clip corpus
  - ≥35% compression vs non-optimized at Balanced (was ≥30% in v0.3)
  - ≥55% compression on the signage 10-clip subset at Maximum (was ≥50% in v0.3)

#### B.6 PocketDVDNet evaluation (lower priority, parallel)

- Implement PocketDVDNet (arXiv:2601.16780); 5-frame patch input
- Compare against NAFNet on the same multi-degradation corpus
- **Decision rule**: swap only if PocketDVDNet beats NAFNet by ≥0.3 dB at ≤74% the size
- File ADR: `Forge/Documentation/ADRs/2026-XX-pocketdvdnet-vs-nafnet.md`

### Phase C — ForgeUpscaler Playback Tier (Weeks 3-5, parallel with B)

**Goal**: SPANV2 replaces SRVGGNetCompact in the playback tier.

#### C.1 Weight acquisition + license verification (BLOCKING)

- Track `github.com/Amazingren/NTIRE2026_ESR` for weight release
- **License gate**: must be permissive (Apache 2.0, MIT, BSD) for commercial use
- Fallback ladder if non-commercial:
  1. **PDS** (BOE_AIoT, pruned/distilled SPANF — 2nd place, same paper)
  2. **PKDSR** (3rd place, same paper)
  3. Train SPANV2 from scratch using the published architecture (~14 days on M5 Pro)
- Document in `Packages/ForgeUpscaler/LICENSES.md`
- **Acceptance**: License confirmed commercial-compatible OR fallback adopted with rationale

#### C.2 SPANV2 MLX-Swift implementation

- Architecture: near-pixel branch (pixel-repeat upsampling prior) + 5 SPABV2 blocks + depthwise-separable fusion + PixelShuffle
- The `span_attn_op` CUDA kernel fusion does NOT port directly; rely on `mx.compile` for fusion on Metal
- File: `Packages/ForgeUpscaler/Sources/ForgeUpscaler/Playback/SPANV2.swift`
- **Acceptance**: Forward pass on 256×256 input produces 1024×1024 output (4× SR) within FP16 tolerance of PyTorch reference

#### C.3 Weight conversion

- Script: `Packages/ForgeTraining/Scripts/convert_spanv2_to_mlx.py`
- PyTorch state dict → MLX `.safetensors` → `.mlpackage`
- **Acceptance**: Output matches PyTorch within FP16 tolerance

#### C.4 Benchmark vs SRVGGNetCompact (DECISION GATE) — RESOLVED (ADR-0008)

- **Resolved**: the gate ran as EfRLFN vs SRVGGNetCompact (ADR-0006 superseded
  SPANV2). SRVGGNet-general won decisively on **quality** (+26.8 VMAF); EfRLFN
  rejected. See [ADR-0008](ADRs/0008-phase-c4-ab-verdict-srvggnet.md).
- The original throughput half of the decision rule is **void per ADR-0009** —
  realtime is no longer a Forge requirement. VMAF (quality) was the deciding axis.

#### C.5 Integration

- Wire chosen model into `ForgeUpscaler.PlaybackTier`
- Update Forge TV preview enhancement (Forge PRD v0.3 Phase 4) to use the chosen model
- **Acceptance**: quality + bundle gates pass. (The former "≥30 fps on Apple TV
  4K" acceptance is dropped per ADR-0009 — realtime is a separate-project concern.)

### Phase D — ForgeUpscaler Export Tier (Week 5)

**Goal**: Adopt the existing `themindstudio/RealESRGAN-x4plus-mlx` MLX port as the export tier today; scaffold OSEDiff for the future.

#### D.1 Real-ESRGAN MLX adoption

- License audit: confirm BSD-3-Clause terms, include LICENSE text in `Packages/ForgeUpscaler/LICENSES.md`
- Wrap the port behind `ForgeUpscaler.ExportTier` protocol
- File: `Packages/ForgeUpscaler/Sources/ForgeUpscaler/Export/RealESRGAN_MLX.swift`
- **Acceptance**: 1080p → 4K export completes; output matches PyTorch reference within LPIPS 0.01

#### D.2 Tiled inference

- Reuse ForgeOptimizer tiling: 256×256 model input, 32px overlap, linear blending
- **Acceptance**: 4K → 8K and arbitrary-resolution inputs produce seamless output (no visible tile boundaries on the 30-clip corpus)

#### D.3 OSEDiff stub (FUTURE)

- Create `Packages/ForgeUpscaler/Sources/ForgeUpscaler/Export/OSEDiff_MLX.swift` with the protocol surface but no implementation
- Implementation deferred until DiffusionKit's SD 2.1 path matures (estimate 2026 Q3)
- **Acceptance**: Protocol compiles; runtime throws `ForgeUpscalerError.notYetImplemented` with a clear message

### Phase E — QualityRegressor Upgrade (Weeks 6-8)

**Goal**: Replace the bespoke CNN QualityRegressor with a SigLIP2 NR-IQA head.

#### E.1 SigLIP2 backbone acquisition

- Pull SigLIP2-base from `mlx-community` on Hugging Face (already MLX-ported)
- Verify Apache 2.0 license; document in `LICENSES.md`
- **Acceptance**: Image encoder produces expected embedding dimension on test images

#### E.2 NR-IQA head implementation

- 2-layer MLP on top of SigLIP2 image embeddings → scalar quality score in [0, 1]
- Activation: Swish or GELU per the arXiv:2509.17374v2 ablation
- File: `Packages/ForgeOptimizer/Sources/ForgeOptimizer/QualityRegressor/SigLIP2_IQA.swift`
- **Acceptance**: Stable forward output across the test corpus

#### E.3 Training corpus

- KonIQ-10k + SPAQ + custom signage MOS corpus
- Custom signage MOS collection: 500 clips × 5 internal raters (Likert 1–5, normalized to MOS)
- **Acceptance**: ≥3000 labeled images across all sources

#### E.4 Training (Python, M5 Pro)

- Freeze SigLIP2 backbone; train head only
- Loss: PLCC + Spearman rank loss
- Schedule: 100 epochs, AdamW LR 1e-3
- Script: `Packages/ForgeTraining/Python/train_siglip2_iqa.py`
- **Acceptance**:
  - Test-set SRCC ≥0.90
  - LCC ≥0.92
  - Signage-subset SRCC ≥0.88

#### E.5 Integration

- Replace `QualityRegressor` calls in `ForgeOptimizer.AnalysisPass`
- Output feeds per-frame bitrate multipliers in `EncodingProfile`
- Move legacy CNN to `QualityRegressor/Legacy/`
- **Acceptance**: Per-frame quality scores correlate (r ≥ 0.85) with VMAF in the analysis pass

### Phase F — Signage Fine-Tune (Weeks 8-10, optional/parallel)

**Goal**: Apply character-and-word-length text-aware loss to ForgeUpscaler's signage path.

#### F.1 Text-aware loss

- Implement character-prior + word-length loss from Nie et al., Pattern Recognition vol. 173, May 2026 (DOI 10.1016/j.patcog.2025.112869)
- Training-only term; not part of inference
- File: `Packages/ForgeTraining/Python/text_aware_loss.py`
- **Acceptance**: Loss converges on TextZoom; spot-check confirms preserved text edges

#### F.2 Signage fine-tune

- Start from SPANV2 (playback) and Real-ESRGAN (export) weights
- Fine-tune on signage corpus + TextZoom for ~4.5 days on M5 Pro
- **Acceptance**: OCR accuracy on rendered signage clips ≥+5% vs base SPANV2/Real-ESRGAN

### 3.5 Dependency Graph

```
A.1 → A.2 → A.3 ─┬─→ B.1 → B.2 → B.3 → B.4 → B.5 ┬─→ Pipeline benchmarks (§4)
                 ├─→ B.6 (parallel)               │
                 ├─→ C.1 → C.2 → C.3 → C.4 → C.5 ─┤
                 ├─→ D.1 → D.2                    │
                 ├─→ D.3 (stub only)              │
                 └─→ E.1 → E.2 → E.3 → E.4 → E.5 ─┘
                                                  │
                                                  └─→ F.1 → F.2 (optional)
```

---

## 4. Pipeline-Level Acceptance Gates

After all phases (excluding F, which is optional), the integrated pipeline must hit:

| Metric                                | Old (v0.3 PRD)      | New target          | Where measured           |
| ------------------------------------- | ------------------- | ------------------- | ------------------------ |
| Bundle size (`.mlpackage` total)      | ~14 MB              | ≤12 MB              | `du Resources/Models/`   |
| VMAF @ Balanced                       | ≥90                 | ≥90                 | 30-clip corpus           |
| Compression vs non-optimized @ Balanced | ≥30%              | ≥35%                | 30-clip corpus           |
| Compression @ Maximum (signage)       | ≥50%                | ≥55%                | Signage 10-clip subset   |
| QualityRegressor SRCC vs human MOS    | not measured        | ≥0.90               | KonIQ + signage holdout  |

> **Realtime gates removed (ADR-0009).** The former `Throughput @1080p Balanced
> ≥0.7× realtime` and `Playback tier ≥30 fps 1080p→4K` gates are **dropped** —
> realtime performance is a separate-project concern, not a Forge requirement.
> Throughput (`fps_mean` / `realtime_factor`) is still measured and reported,
> just not gated. The benchmark catalog is now 5 gates (quality/size/compression).

---

## 5. Risk Register

| #  | Risk                                                                 | Mitigation                                                                  |
| -- | -------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| 1  | SPANV2 weights released non-commercial                               | Fallback to PDS or PKDSR (same paper, same family)                          |
| 2  | `span_attn_op` CUDA fusion doesn't translate; SPANV2 win shrinks     | Hard decision gate at C.4; SRVGGNetCompact stays if threshold missed        |
| 3  | NAFNet regresses on a specific degradation (e.g. AV1)                | Per-degradation A/B in B.5; fall back to per-degradation models if needed   |
| 4  | SigLIP2 backbone too large for in-app bundle                         | Use SigLIP2-base (smallest variant); evaluate distillation in next cycle    |
| 5  | MLX 0.31.2 conv3d speedup breaks numerical equivalence on legacy     | A.1 catches this; pin to 0.30.x if catastrophic                             |
| 6  | NTIRE 2026 repo doesn't publish weights in time                      | Train SPANV2 from scratch (~14 days on M5 Pro from architecture spec)       |
| 7  | SigLIP2 license audit drags                                          | SigLIP v1 confirmed Apache 2.0 as fallback                                  |
| 8  | M5 Pro training time blows out                                       | Reduce iterations 300K → 150K and accept ~0.2 dB PSNR loss                  |
| 9  | NAFNet 3-in-1 hits a "jack of all trades" wall                       | Keep DnCNN-gray for monochrome content as a fast path (small model)         |
| 10 | Real-ESRGAN MLX port stale or buggy                                  | Fall back to in-house RRDBNet port already specified in ForgeUpscaler PRD   |

---

## 6. Out of Scope (This Iteration)

- LiteFlowNet → CoreML conversion (separate workstream, near-complete)
- SeedVR2 integration (watch-list; revisit after M5 Max benchmarks land)
- OSEDiff full implementation (stub only at D.3)
- ViSAGE-distilled saliency (Apple Vision saliency stays for now)
- DCVC-RT or any full-neural-codec replacement
- NTIRE 2026 UGC VR winners (RedMediaTech, Lucky one, BVI) — too heavy for Apple Silicon today
- Any change to the VideoToolbox encoder path or FFmpeg decoder configuration
- Marquee Studio Pro PRD-side changes (separate document)
- Top Shelf integration on Apple TV home screen (Forge PRD v0.3 Phase 4)

---

## 7. References

**Internal:**

- Forge PRD v0.3 (especially §10 — Key Technical Decisions)
- ForgeUpscaler PRD
- 45-Day Re-Evaluation Report (May 2026)

**Papers and repos:**

- NTIRE 2026 ESR Challenge — arXiv:2604.03198 (SPANV2)
- PocketDVDNet — arXiv:2601.16780
- NAFNet — arXiv:2204.04676; `github.com/megvii-research/NAFNet`
- SigLIP2 NR-IQA — arXiv:2509.17374v2
- Text-aware SR loss — Pattern Recognition vol. 173 / DOI 10.1016/j.patcog.2025.112869
- Real-ESRGAN MLX port — `huggingface.co/themindstudio/RealESRGAN-x4plus-mlx` (BSD-3-Clause)
- MLX-Swift releases — `github.com/ml-explore/mlx-swift/releases`

---

## 8. First Tasks for the Coder

In order, no skipping:

1. Read this document in full
2. Read Forge PRD v0.3 §10 (Key Technical Decisions) and ForgeUpscaler PRD §1–§3
3. Cut branch `feature/forge-2026-q2-refresh` from `main`
4. Phase A.1 — bump MLX-Swift; run full test suite; fix any breakage
5. Phase A.2 — wire benchmark harness; capture baselines (both old and new MLX)
6. Phase A.3 — create `ModelRegistry` actor; migrate legacy model loading through it
7. **STOP** and report baseline benchmark JSON to Dustin before starting Phase B or C

After the Phase A gate, B and C proceed in parallel. D is a fast follow once C.1 has license confirmation. E starts after A but can run independently. F starts after both C.5 and D.1 land.

---

End of plan.
