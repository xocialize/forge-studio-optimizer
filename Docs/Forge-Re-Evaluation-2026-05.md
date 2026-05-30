# Forge Pipelines — 45-Day Re-Evaluation Report

**Period covered**: ~2026-04-01 → 2026-05-15
**Report date**: 2026-05-26
**Author**: Dustin / MVS Collective
**Status**: Draft — stub reconstruction from coding plan §0

---

## 0. Document Status

This report is a stub reconstructed from `Docs/Forge-CodingPlan-v1.0.md` §0, which referenced this document as one of its three inputs. The original was on a different dev machine and is not available. Treat the bullet list of findings below as the authoritative summary of what the re-evaluation produced; the prose framing is reconstructed and should be refined when the source notes are recovered (or replaced entirely by an updated re-eval).

---

## 1. Scope

Forty-five days after the v0.3 PRD landed, re-evaluate every learned component in the Forge stack against the literature and the ecosystem state of May 2026. Question: does the speed/quality/size Pareto frontier of any single component have a meaningfully better neighbor we can adopt without disrupting the two-pass architecture, the CVPixelBuffer handoff, the FFmpeg decoder, or the VideoToolbox encoder?

Five components were evaluated:

1. **ForgeOptimizer restoration** (DnCNN-color + DnCNN-gray + ARCNN — three models for joint denoise + artifact removal)
2. **ForgeOptimizer quality regressor** (bespoke CNN)
3. **ForgeUpscaler playback tier** (SRVGGNetCompact)
4. **ForgeUpscaler export tier** (in-house RRDBNet port, partly written)
5. **MLX-Swift baseline** (pinned at 0.21.0 in the existing repo; 0.30.x / 0.31.2 available)

Saliency, motion (LiteFlowNet), and the SoftROIFilter were re-evaluated and held — no meaningful upgrade available.

---

## 2. Findings & Recommendations

### 2.1 Restoration consolidation: DnCNN×2 + ARCNN → single NAFNet
**Finding**: `megvii-research/NAFNet` (MIT) handles Gaussian noise, HEVC, AV1, and MPEG-2 artifacts in one model at width=32, blocks=8 (~1.1 GMACs, ≤6 MB). The three current models combined are ~9 MB.
**Recommendation**: Replace with NAFNet. ~33% bundle reduction; one model load instead of three; PSNR comparable on per-degradation evaluation (within 0.3 dB of dedicated ARCNN on HEVC).
**Risk**: Jack-of-all-trades regression on a single degradation type. Mitigation: per-degradation A/B in Phase B.5; keep DnCNN-gray as a fast path for monochrome.

### 2.2 QualityRegressor upgrade: CNN → SigLIP2 NR-IQA head
**Finding**: Per arXiv:2509.17374v2, a SigLIP2-base backbone (Apache 2.0, MLX-ported on Hugging Face) plus a 2-layer MLP head achieves SRCC ≥ 0.90 on KonIQ-10k. The current bespoke CNN was never measured against human MOS.
**Recommendation**: Adopt SigLIP2-base + frozen-backbone trained head. Adds a SigLIP2 dependency but the head training is fast and the qualitative ceiling rises substantially.
**Risk**: SigLIP2-base inflates bundle. Mitigation: it's still ≤ ~80 MB; distillation in a later cycle.

### 2.3 Playback tier upgrade: SRVGGNetCompact → SPANV2
**Finding**: SPANV2 won NTIRE 2026 ESR with a near-pixel branch + SPABV2 blocks + depthwise-separable fusion. PyTorch reference shows ≥ 1.2× throughput vs SRVGGNetCompact at equal-or-better quality on CUDA via `span_attn_op` kernel fusion.
**Recommendation**: Adopt **conditional on the Metal-side fusion advantage transferring** (Phase C.4 gate). If `mx.compile` recovers the fusion, swap; otherwise hold.
**Risk**: NTIRE weights may release non-commercial. Fallback ladder: PDS → PKDSR → train from scratch (~14 days on M5 Pro).

### 2.4 Export tier upgrade: in-house RRDBNet port → themindstudio Real-ESRGAN MLX
**Finding**: `huggingface.co/themindstudio/RealESRGAN-x4plus-mlx` (BSD-3-Clause) is a working MLX port of Real-ESRGAN-x4plus. Completing the in-house RRDBNet port no longer pays for itself.
**Recommendation**: Adopt the existing port; wrap behind `ForgeUpscaler.ExportTier`. Document license in `LICENSES.md`.
**Risk**: Port stale or buggy. Mitigation: fall back to in-house RRDBNet port (PRD already specifies it). Note: `com.xocialize.coreml/models/macos/realesrgan_x4.mlpackage` is also available as a backup data point.

### 2.5 MLX-Swift baseline: 0.21 → 0.31.2
**Finding**: `mlx 0.31.2` adds a 3D-conv speedup relevant to any multi-frame restoration path. `mlx-swift` currently on 0.21.0 — multiple breaking changes between (notably `QuantizedLinear.bias` becoming optional).
**Recommendation**: Bump in a single foundational phase (A.1), step-stepped through intermediate tags rather than single-shot. Capture before/after benchmarks.
**Risk**: Breaks legacy DnCNN/ESPCN/ARCNN paths during transition. Mitigation: stage the bump (0.21 → 0.24 → 0.27 → 0.31.2); pin to 0.30.x if anything irrecoverable.

### 2.6 Watch-list — held items
- **PocketDVDNet** (arXiv:2601.16780, 5-frame patch input) — evaluate against NAFNet on multi-degradation corpus; swap only if ≥ 0.3 dB better at ≤ 74% the size
- **ViSAGE-distilled saliency** — Apple Vision saliency stays for now
- **OSEDiff** — DiffusionKit SD 2.1 path needs to mature first (est. 2026 Q3)
- **SeedVR2** — revisit when M5 Max VRAM headroom is confirmed
- **DCVC-RT / full-neural-codec** — too immature
- **NTIRE 2026 UGC VR winners** (RedMediaTech, Lucky one, BVI) — too heavy for Apple Silicon today

---

### 2.6 Update — External research delivered 2026-05-26 PM

After the initial findings above landed, an external research pass investigated three open questions: small-footprint NR-IQA alternatives, the post-NTIRE-2026-ESR landscape, and neural-codec viability on Apple Silicon. Three outcomes:

**Phase C unfreeze — EfRLFN** (the biggest delta). [Survey 2](Research/research-2026-05-26-three-surveys.md) identified `EfRLFN` (arXiv:2602.11339, ICLR 2026, Bogatyrev et al. / Lomonosov MSU, **MIT**) as a permissive non-NTIRE alternative for the playback tier — paper abstract cited ~300K params, but the C.2 MLX-Swift port (Task #18, 2026-05-27) verified **~504K params / ~1.0 MB FP16** at upstream defaults; pure conv + ECA + tanh — outperforming NVIDIA VSR, SPAN, and stock RLFN on user-preference-vs-runtime Pareto. The original ADR-0004 hold (waiting for NTIRE 2026 weight releases) is therefore the wrong dependency; **adopt EfRLFN behind a feature flag now**, per [ADR-0006](ADRs/0006-phase-c-unfreeze-efrlfn.md). One caveat: EfRLFN was trained on StreamSR (YouTube-derived), so any MVS-side fine-tune needs legal review on YouTube ToS first. Fallback ladder: SAFMN++ (MIT) → SPAN baseline (Apache-2.0). SPANV2 stays on a 60-day re-check loop because its NTIRE win came largely from a CUDA fused kernel (`span_attn_op`) that won't port to Metal.

**Phase E confirmed — SigLIP2 lazy-download is the right path** (no swap fallback exists). [Survey 1](Research/research-2026-05-26-three-surveys.md) found that no permissive ≤10 MB NR-IQA model meets SRCC ≥0.88 on KonIQ-10k. Every candidate that hits the quality bar is either too large (MUSIQ at 54 MB, MANIQA at 270 MB) or non-permissive (CLIP-IQA+, QualiCLIP+, TOPIQ, LIQE, ARNIQA — NTU S-Lab 1.0 or CC-BY-NC 4.0). [ADR-0005](ADRs/0005-siglip2-lazy-download.md) stands. The realistic Plan B is retraining a MobileNet-V3 student on QualiCLIP+ pseudo-labels (documented in `Packages/ForgeOptimizer/LICENSES.md` under Phase E Plan-B); Plan C is a tactical port of MUSIQ-single-scale to MLX-Swift (~1 engineer-week, ~54 MB FP16).

**Plan §6 holds — neural codecs stay on the watch-list**. [Survey 3](Research/research-2026-05-26-three-surveys.md) confirmed DCVC-RT (Microsoft, MIT) is the closest viable neural codec — −21% BD-rate vs H.266/VTM — but at 39.5/34.1 fps encode/decode on an RTX 2080 Ti and dependent on custom CUDA fused kernels plus a C++ entropy coder. Realistic Apple Silicon port: 8–12 engineer-weeks for a baseline that would still trail A100 numbers. Re-evaluate 2026-Q3. Same hold for VCT, NTIRE 2026 UGC VR winners.

**New benchmarks-that-change-recommendations** (lifted from the research's cross-survey conclusion §):

- EfRLFN A/B shows VMAF gain <0.5 → fall back to SAFMN++
- SigLIP2 lazy-download P95 latency >10 s on cellular → accelerate the MobileNet-V3 distillation track to MVP
- A DCVC-RT Apple Silicon port appears with measured M-series fps ≥15 at 1080p → re-evaluate as a ForgeOptimizer codec-tier addition

Source document: [Docs/Research/research-2026-05-26-three-surveys.md](Research/research-2026-05-26-three-surveys.md).

---

## 3. What Did Not Change

- Two-pass architecture (analysis → preprocess + encode)
- CVPixelBuffer handoff between FFmpegDecoder, ForgeOptimizer, NativeEncoder
- ForgeOptimizer SPM-package boundary (shared with Marquee Studio Pro)
- Apple Vision saliency (`VNGenerateAttentionBasedSaliencyImageRequest`)
- LiteFlowNet → CoreML conversion (separate workstream, near-complete)
- VideoToolbox encoder and FFmpeg decoder configuration
- Conventions: arm64 only, no Python at runtime, `LicensePolicy` enforcement, `weightLicense: SPDXLicense` on every model

---

## 4. Outputs Consumed By

- `Docs/Forge-CodingPlan-v1.0.md` — the implementation sequence
- `Docs/Forge-BenchmarkSchema-v1.0.md` — the report format for measuring the new state
- `ForgeUpscaler-PRD-v0.1.md` (this PR) — narrows down the planned upscaler refresh

---

End of stub.
