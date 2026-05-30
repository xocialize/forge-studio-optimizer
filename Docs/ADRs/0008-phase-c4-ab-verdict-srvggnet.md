# ADR 0008 — Phase C.4 A/B Verdict: Ship SRVGGNetCompact-general, Reject EfRLFN

**Date**: 2026-05-29
**Status**: Accepted
**Branch**: `feature/forge-2026-q2-refresh`
**Supersedes**: the provisional "adopt EfRLFN as the playback default" decision in [ADR-0006](0006-phase-c-unfreeze-efrlfn.md) (ADR-0006's unfreeze + port-and-A/B framing stands; only its expected outcome is reversed)
**Triggered by**: the Phase C.4 A/B benchmark — `Docs/Benchmarks/benchmark-c4-ab-v2-e06ff85.json`

---

## Context

ADR-0006 lifted the Phase C freeze, adopted EfRLFN behind a flag, and made the C.4 A/B the decision gate: EfRLFN ships to default **iff** it beats SRVGGNetCompact by **≥ +1.0 VMAF** on a genre-diverse corpus **and** holds throughput parity. C.2 ported EfRLFN, C.3 verified PyTorch↔MLX parity, C.5a wired a dual-backend `PlaybackTier`, and Task #28 vendored three SRVGGNetCompact variants (general / general-wdn / anime) as MLX-Swift.

Phase C.4 ran all four backends over the full 30-clip corpus with a proper full-reference SR methodology (downscale ÷4 → super-resolve → VMAF vs the original HR frame). Two pipeline bugs were found and fixed before the numbers were trustworthy:

- The SSIM=1.0 tautology in the upscaler pass (compared output to itself) — removed.
- **The decisive one:** `MLXTileProcessor` read the decoder's **NV12** (biplanar YUV) output as packed **BGRA**, feeding every SR backend a sheared, grayscale luma plane. Output was diagonal garbage; VMAF was meaningless (~13 mean, many clips 0). Fixed by normalising any non-BGRA input to BGRA via CoreImage before tile extraction. The playback tier had **never** produced correct output prior to this — v1's SSIM=1.0 masked it; the proper-VMAF C.4 run was the first real pixel comparison.

## Decision

**Adopt `SRVGGNetCompact realesr-general-x4v3` (BSD-3-Clause) as the playback-tier default. Do NOT ship EfRLFN.**

`PlaybackUpscaler.Backend.defaultGeneral` → `.srvggnetGeneral(scale: 4)`; the preset shim routes both general and anime presets to SRVGGNetCompact variants. EfRLFN stays selectable via `init(backend:)` for future re-evaluation but is not wired as a default anywhere.

### Evidence — C.4 A/B, 4 backends × 30 clips, 120/120 success

Mean VMAF (0–100, higher better) / mean fps at the 270p→1080p quality workload:

| Backend | VMAF | fps | general | signage | legacy |
|---|---|---|---|---|---|
| **srvggnet-general-x4** | **77.96** | 102.9 | 78.1 | 90.4 | 65.4 |
| srvggnet-general-wdn-x4 | 72.90 | 102.1 | 72.0 | 86.7 | 60.0 |
| srvggnet-anime-x4 | 71.62 | 154.6 | 72.4 | 83.3 | 59.2 |
| efrlfn-x4 | 51.12 | 94.7 | 54.7 | 56.8 | 41.9 |

- **EfRLFN fails the ship criterion on every clip: 0 / 30** meet `≥ general + 1.0`. It is **−26.8 VMAF** behind SRVGGNet-general on average, loses in all three categories, and is **slightly slower** (94.7 vs 102.9 fps) — so it fails both halves of the criterion, not just quality.
- Visual confirmation (Sintel close-up): SRVGGNet-general resolves crisp hair/edge detail; EfRLFN is soft, roughly bicubic-level. Bicubic baselines cross-check the harness (static-logo bicubic 59.2 ≈ EfRLFN 59.7; transition bicubic 97.46 = both backends), confirming the measurement is sound and EfRLFN genuinely under-enhances on this distribution.

### Why SRVGGNet-general over the other SRVGGNet variants

Highest VMAF across all three categories; general-wdn trades sharpness for denoising (lower VMAF here), anime is faster but tuned for animation. General is the right default; anime stays routed for `.anime` content.

### Bonus consequences

- **Drops the StreamSR legal dependency for playback.** Task #19's StreamSR review existed because EfRLFN's weights were trained on YouTube-derived UGC. Not shipping EfRLFN removes that from the playback ship path entirely. SRVGGNet-general is BSD-3-Clause with Real-ESRGAN provenance.
- **Closes the pre-refresh gap** where `PlaybackUpscaler` referenced never-vendored `SRVGGNet_*` CoreML mlpackages — the MLX-Swift SRVGGNet port (Task #28) is now the shipping path.

## Caveat / Revisit triggers

- **Eval distribution.** C.4 used clean bicubic LR (DIV2K-style). EfRLFN was trained on StreamSR (compressed UGC) and was not tested on its home turf. A 26.8-point gap is implausible to flip — and SRVGGNet's Real-ESRGAN degradation training generalises to degraded input too — but a degradation-aware re-eval is the fair confirmation if the UGC use case becomes primary.
- **Throughput caveat.** The fps above are for 270p→1080p (the quality workload), a valid *relative* parity check. Absolute "1080p→4K ≥30 fps" (Plan §4) is a separate measurement not run here.
- If a future ESR model ships permissive weights + a Metal-friendly architecture that beats SRVGGNet-general on a re-run, standard re-evaluation applies (mirrors ADR-0006's revisit clause). SAFMN++ (ADR-0006 fallback ladder #1) remains the first candidate to *try to beat* SRVGGNet-general, deferred unless there's appetite.

## References

- C.4 report: `Docs/Benchmarks/benchmark-c4-ab-v2-e06ff85.json`
- Fix commits: SSIM tautology (4c26953), SR methodology (79f3e53), NV12→BGRA (e06ff85)
- [ADR-0006](0006-phase-c-unfreeze-efrlfn.md) — the unfreeze + A/B-as-gate decision this resolves
- EfRLFN: arXiv:2602.11339 (ICLR 2026); SRVGGNetCompact / Real-ESRGAN: `xinntao/Real-ESRGAN` (BSD-3-Clause)
