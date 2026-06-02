# ADR 0021 — Still quality-target search reuses the FormatBridge scorer/search seam

**Date**: 2026-05-31
**Status**: Accepted (implemented ImageBridge Phase 1/2, 2026-06-01)
**Driven by**: `Docs/ImageBridge-PRD-v0.1.md` §6
**Mirrors**: [ADR-0013](0013-videotoolbox-first-ship-encoder.md)/[ADR-0014](0014-revise-compression-gate.md) (VMAF-targeted rate control), the Step-1 `QualityTargetSearch` core

---

## Context

The highest-ROI work on the video side is **VMAF-targeted quality search**:
`QualityTargetSearch` runs a sample-encode binary search over the VideoToolbox quality knob
to find the smallest encode clearing a perceptual floor, with the metric injected via
`QualityScoring` (`FFmpegVMAFScorer` lives in the runner — **FormatBridge does not link
libvmaf**). That separation kept the LGPL libvmaf entanglement out of the product (ADR-0013
amendment to ADR-0002).

"Leverage the video optimization for post-conversion" (the companion-app ask) becomes
**literal** if the still path reuses this architecture: same binary search, same injection
seam, different knob and metric.

Two substitutions are needed:

- **The knob.** Video drives the VideoToolbox quality parameter. Stills drive the still
  encoder's quality parameter (JPEG/HEIC/AVIF/WebP quality 0–100).
- **The metric.** VMAF is a *video* metric (temporal, motion-aware) — wrong for a single
  frame. Stills need a still perceptual metric.

## Decision

**Add `StillQualityTargetSearch` with the identical `scorer` / `search` injection shape as
FormatBridge, and keep the metric out of the bridge.**

1. **`StillQualityTargetSearch`** — binary-searches the still encoder's quality parameter for
   the smallest file clearing a perceptual floor. Structurally identical to
   `QualityTargetSearch`; composes via `ImageBridgeFactory.makeQualityTargetEncoder(
   scorer:search:)`, matching `FormatBridgeFactory`.
2. **`StillQualityScoring` seam** — the perceptual metric is **injected from the runner/CLI,
   not linked into ImageBridge** (the exact libvmaf separation from ADR-0013). Two
   implementations:
   - **Full-reference: SSIMULACRA2** (`ssimulacra2` Rust crate, BSD-3 — vendors cleanly).
     The recommended full-ref default; needs the pre-degradation original.
   - **No-reference: the SigLIP2 NR-IQA head** already queued in
     `ForgeOptimizer/QualityRegressor`. Needs no original — the right floor when the
     "original" is itself degraded signage (the common ForgeStudio case).
3. **Lossless short-circuit.** When the target format is lossless (PNG via oxipng, ADR-0020),
   there is no quality knob to search — the search is skipped and the lossless optimizer runs
   directly. The search applies only to the lossy ship/opt-in formats (JPEG/HEIC/AVIF/WebP).

## Consequences

- **The crown-jewel reuse is real, not aspirational.** Swap VMAF→SSIMULACRA2/NR-IQA and the
  VT knob→the still-encoder knob; the search/compose/inject architecture is unchanged.
- **No new licensing surface in the product.** The metric stays in the dev/measurement path
  (like libvmaf); SSIMULACRA2 is BSD-3 and the NR-IQA head is already in-tree.
- **The default-metric choice is a real fork (PRD §12, open).** SSIMULACRA2 (full-ref) is
  more standard but assumes a clean original; NR-IQA is more honest on already-degraded
  signage. Recommendation: **NR-IQA as the v1 default for the signage corpus**, SSIMULACRA2
  available for clean-source workflows — but this is the owner's call and is gated on the
  QualityRegressor training landing.
- **Dependency ordering.** The NR-IQA scorer depends on the SigLIP2 IQA training already
  queued in ForgeOptimizer; until that lands, SSIMULACRA2 is the only available floor. This
  sequences the still quality-target work behind (or alongside) the IQA track.

## Revisit triggers

- A better open still metric than SSIMULACRA2 reaches maturity → swap the full-ref scorer; no
  architecture change (it's behind the seam).
- The QualityRegressor IQA head ships and validates → promote NR-IQA to default per the §12
  decision.

## References

- `Docs/ImageBridge-PRD-v0.1.md` §6
- SSIMULACRA2: `ssimulacra2` crate (BSD-3). NR-IQA: `ForgeOptimizer/QualityRegressor` (SigLIP2).
- [ADR-0013](0013-videotoolbox-first-ship-encoder.md), [ADR-0014](0014-revise-compression-gate.md)
- [ADR-0019](0019-imagebridge-sibling-package.md), [ADR-0020](0020-still-ship-encoder.md)
