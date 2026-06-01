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

| encoder @ VMAF≈95 (1080p abacus) | bitrate | vs **our** VT-HEVC |
|---|---|---|
| **our ship VideoToolbox HEVC** (`VTCompressionSession`, VMAF-targeted) | **~0.37 Mbps** | — |
| AV1 SVT-AV1 preset 6 (Step 4) | ~0.16 Mbps | 57% smaller |
| x265 veryslow | ~0.22 Mbps | 41% smaller |
| x264 veryslow `--tune animation` | ~0.48 Mbps | 30% *larger* |
| ~~ffmpeg `hevc_videotoolbox -q:v`~~ (measurement artifact) | ~~0.84 Mbps~~ | ignore |

Two things fall out:
1. **A real software-premium gap exists** — but **AV1 (already shipped, Step 4) is the smallest
   AND the only license-clean option** (BSD-3 + AOM patent grant, royalty-free). x264/x265 are
   GPL-or-commercial + H.264/HEVC patent obligations. (x264 is actually *larger* than our HEVC here
   — H.264's codec disadvantage outweighs its finer RC on this content.)
2. **Our VT-HEVC is healthy** — ~41% behind x265-veryslow on graphics (the *normal* hardware-vs-
   software HEVC tradeoff; even competitive with x265-medium on very flat content like sevilla,
   0.13 Mbps @ 94.6). **CORRECTION (#59):** an earlier draft of this ADR cited a ~74% gap — that was
   measured against ffmpeg's `hevc_videotoolbox -q:v` *wrapper* (~0.84 Mbps), which is ~2.3× less
   efficient than our direct VTCompressionSession use. Measuring the **actual ship encoder** (above)
   corrected it: no default-path problem. (Validate-the-measurement, not the harness — same lesson
   family as the VMAF-reference catch, #55.)

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
- **#59 RESOLVED (verified — no fix needed):** the "VT-HEVC is dramatically inefficient" alarm was
  a measurement artifact (ffmpeg's `-q:v` wrapper, not our encoder). Our actual `VTCompressionSession`
  HEVC is healthy (~41% behind x265-veryslow on graphics — the normal hardware tradeoff; competitive
  with x265-medium on flat content). No VideoToolbox settings change warranted. The takeaway is the
  positioning above: route signage to AV1 where the target decodes it; VT-HEVC stays the default.

## References

- `Docs/Benchmarks/av1-tier.md` (AV1 measurement + the shared A/B harness)
- [ADR-0017](0017-av1-tier-svtav1-subprocess-phase-a.md) — AV1 tier
- [ADR-0015](0015-per-shot-deferred-on-videotoolbox.md) — per-shot deferred (same pattern)
- #53 (Steps 5/6), #59 (VT-HEVC settings follow-up)
