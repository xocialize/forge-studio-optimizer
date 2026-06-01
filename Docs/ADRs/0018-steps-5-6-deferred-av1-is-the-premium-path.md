# ADR 0018 — Steps 5/6 (x264 premium, convex-hull) deferred; AV1 is the premium path

**Date**: 2026-06-01
**Status**: Accepted
**Driven by**: Step 5/6 (#53) — the research roadmap's *conditional/high-end* tail; builds on
ADR-0013 (VideoToolbox-first), ADR-0017 (AV1 tier), and ADR-0015 (per-shot deferred, the same
"measure then defer a conditional step" pattern).

---

## Context

The research doc (`forge-studio-encoding-strategy-v2.md`) lists two *conditional* tail steps:
- **Step 5 — licensed-x264 quality-premium path:** VideoToolbox's quality knob is coarser than
  x264 CRF and lacks clean-content micro-levers (`--tune animation`, psy-rd), so a licensed x264
  path *could* close the residual gap — but only "if A/B testing proves the quality-per-bit gap
  justifies the spend" (x264 carries GPL + a Via-LA H.264 patent obligation).
- **Step 6 — convex-hull over resolutions:** "adds a few % + right-sizes resolution," the
  high-end full-hull search.

## Findings (A/B, matched VMAF ≈95 on graphics signage — 1080p abacus)

| encoder | size @ VMAF 95 | vs VT-HEVC |
|---|---|---|
| **VT-HEVC** (our ship encoder, hevc_videotoolbox `-q:v`) | ~1580 KB | — |
| x264 veryslow `--tune animation` | ~900 KB | 43% smaller |
| x265 veryslow | ~410 KB | 74% smaller |
| AV1 SVT-AV1 preset 6 (Step 4) | ~299 KB | 81% smaller |

Two things fall out:
1. **A real software-premium gap exists** — but **AV1 (already shipped, Step 4) is the smallest
   AND the only license-clean option** (BSD-3 + AOM patent grant, royalty-free). x264/x265 are
   GPL-or-commercial + H.264/HEVC patent obligations.
2. **VT-HEVC is far less efficient than x265 on graphics/signage** (~74% gap here) — hardware
   HEVC's coarse RC + lack of clean-content tuning is worst exactly on flat/graphic content (the
   signage norm). (Worst-case content; the gap narrows on camera/photographic input.)

## Decision

- **Step 5 (licensed x264/x265 premium) — DEFER.** The A/B confirms a gap, but the premium need
  is **already met by AV1** (Step 4): smaller than x265 and royalty-free. A *licensed* software
  path would only serve the shrinking HEVC/H.264-only fallback tier and isn't worth the GPL +
  Via-LA patent spend for that alone — the doc's "conditional" condition is not satisfied. Revisit
  only if a concrete target set is HEVC/H.264-only **and** the volume justifies the licensing.
- **Step 6 (convex-hull over resolutions) — DEFER.** Marginal (a few %) for Forge's single-
  rendition, native-resolution, high-quality (VMAF≥95) signage output; the resolution decision is
  already "encode at source res" and playback-side SR handles upscaling. Convex-hull pays for ABR
  ladders / bitrate-starved downscale-then-upscale — revisit if Forge adds multi-rendition/ABR
  delivery. (Same shape as the per-shot defer, ADR-0015.)
- **Encoder roadmap Steps 0–6 are now all resolved:** 0–4 ship (VT HEVC → VMAF-target → per-shot
  deferred → IQA-gated NAFNet → AV1 tier); 5–6 deferred here with measured rationale.

## Consequences / follow-up

- **AV1 (Step 4) is positioned as the efficiency/premium path** for AV1-capable signage targets;
  VT-HEVC remains the universal-compatibility default, VT-H.264 the fallback.
- **Flagged (#59):** VT-HEVC's large efficiency gap vs x265 on graphics is a **default-path**
  issue with **no licensing cost** to fix — verify our VideoToolbox quality/RC settings are
  optimal (constant-quality mapping, multipass, entropy mode) before accepting it as inherent.
  Higher ROI than a licensed premium tier, since it improves the default everyone gets.

## References

- `Docs/Benchmarks/av1-tier.md` (AV1 measurement + the shared A/B harness)
- [ADR-0017](0017-av1-tier-svtav1-subprocess-phase-a.md) — AV1 tier
- [ADR-0015](0015-per-shot-deferred-on-videotoolbox.md) — per-shot deferred (same pattern)
- #53 (Steps 5/6), #59 (VT-HEVC settings follow-up)
