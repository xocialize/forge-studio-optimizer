# ADR 0015 — Per-shot VMAF-targeting deferred (no gain over per-title on VideoToolbox)

**Date**: 2026-05-31
**Status**: Accepted
**Driven by**: Step 2 (#50) implementation + measurement; builds on Step 1 (#49),
ADR-0013 (VideoToolbox-first), and the VMAF-reference fix (#55)

---

## Context

The research roadmap (`forge-studio-encoding-strategy-v2.md`) put **per-shot**
VMAF-targeted rate control as Step 2 — "the differentiator over Vimeo's per-title,"
citing ~10–20% additional savings at equal quality. We built it
(`ShotDetector` + `forge-quality-target --per-shot`: shot-detect → per-shot
VMAF-target search → stitch) and measured it against our **per-title** Step 1
baseline on the **VideoToolbox constant-quality** ship encoder (ADR-0013).

## Findings (measured, cross-checked against independent ffmpeg VMAF)

On a controlled 2-shot clip (easy screencapture + hard sports, 1080p, VMAF≥95):

| variant | result vs per-title |
|---|---|
| **naive** per-shot (each shot to the VMAF floor) | **−18% to −26% (LOSES)** |
| **capped** per-shot (shot quality ≤ per-title quality) | **~0% (TIES)** |

Two reasons per-shot does not pay here:

1. **VideoToolbox constant-quality already adapts bits per-frame.** A per-title
   constant-quality encode already spends few bits on easy frames and many on
   hard ones. The marginal benefit of also lowering the *quality target* on easy
   shots is small — they're already cheap.
2. **Forcing every shot to the same VMAF floor over-serves hard shots.** Per-title
   mean-VMAF targeting lets hard shots ride *lower* (where motion masks artifacts)
   and banks easy shots high — an efficient allocation. Naive per-shot undoes
   that (hard shots grow), and the per-segment **IDR keyframe + rate-control
   warmup** overhead makes it net-negative. Capping at the per-title quality stops
   the loss but leaves only the (small) easy-shot upside → ~0.

The research's larger per-shot win is relative to a **fixed-CRF / fixed-bitrate**
per-title baseline that does *not* adapt per-frame. Against our constant-quality
VBR baseline, that headroom is already captured by Step 1.

## Decision

**Do not ship per-shot for the VideoToolbox encoder.** Step 1 (per-title
VMAF-target on constant-quality VT) is the shipping compression path.

- The `forge-quality-target --per-shot` mode is **retained as validated tooling**
  and is **safe**: it caps shot quality at per-title and **ships
  `min(per-shot, per-title)`**, so it can never regress.
- **Revisit per-shot only with a fixed-CRF x264 premium path (#53)**, where CRF
  is constant per segment and per-shot CRF has real headroom — the regime the
  research result actually describes.

## Consequences

- Step 2 (#50) is **complete as a validated negative result**: mechanism built,
  measured, decision made. Effort not spent on productizing per-shot for VT.
- `ShotDetector` (FormatBridge, 6 tests) stays — useful for per-shot-CRF later and
  for any shot-aware feature. **Known limitation**: global luma-histogram
  signatures missed a talkinghead→sports cut (similar brightness distributions);
  a future per-shot-CRF use would want a stronger signature (chroma / spatial
  blocks) or a lower threshold.
- Reinforces the Step 1 story: the per-title VMAF-target *is* the win on VT.

## References

- `Docs/Benchmarks/step1-native-validation.md` (Step 1 = 63% @ VMAF≥95, cross-checked)
- [ADR-0013](0013-videotoolbox-first-ship-encoder.md) — VideoToolbox-first
- #50 (per-shot), #53 (conditional x264 premium), #55 (VMAF reference fix)
