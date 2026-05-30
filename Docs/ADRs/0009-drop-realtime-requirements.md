# ADR 0009 — Drop Realtime Requirements from Forge

**Date**: 2026-05-29
**Status**: Accepted
**Branch**: `feature/forge-2026-q2-refresh`
**Amends**: [ADR-0006](0006-phase-c-unfreeze-efrlfn.md) (throughput half of the ship criterion), [ADR-0008](0008-phase-c4-ab-verdict-srvggnet.md) (throughput caveat now moot)

---

## Context

Forge's AI super-resolution split into tiers partly on a **realtime** axis: the
`.playback` tier carried a hard "< 33 ms/frame (30 fps)" target and the
benchmark gated on it via two requirements:

- `playback_4k_fps_min` — playback tier ≥ 30 fps at 1080p → 4K (M4 Pro)
- `throughput_balanced_m4pro_1080p` — optimizer ≥ 0.7× realtime at 1080p Balanced (M4 Pro)

Two things make this the wrong fit for Forge:

1. **Realtime SR isn't achievable here anyway, and chasing it is a different
   discipline.** The Phase C.4 real-content run (IBM Think 26 signage) measured
   the shipped SRVGGNet-general at **~7 fps producing 4K output** on M-series —
   an order of magnitude off 30 fps. Closing that gap is a dedicated
   performance-engineering effort (kernel fusion, lower-res output targets,
   frame-pacing, hardware) — a *separate project's track*, not something the
   Forge conversion/optimization codebase should gate itself on.

2. **Forge is a quality-and-compression product, not a realtime player.** Its
   value is "convert once, optimize intelligently" — offline/near-offline
   transcode + AI preprocessing. The realtime-playback concern (e.g. Apple TV
   live enhancement) is a distinct product surface that will be addressed in a
   project suited to that track.

## Decision

**Remove realtime performance as a Forge requirement.** Throughput is still
**measured and reported** (`SpeedMetrics.fpsMean` / `realtimeFactor` in every
run) — it's useful signal — but it is **no longer a pass/fail gate**, and the
tier model is no longer defined by a latency guarantee.

Concretely:

- **GateEvaluator**: the two realtime gates (`playback_4k_fps_min`,
  `throughput_balanced_m4pro_1080p`) are **removed** from the catalog. The
  5 remaining gates are quality/size/compression: `bundle_size_max`,
  `vmaf_balanced_min`, `compression_balanced_min`, `compression_signage_max_min`,
  `quality_regressor_srcc_min`.
- **Tier model** (`ForgeUpscaler`): preview → playback → export becomes a
  **quality/cost spectrum** (fast-light model → slow-heavy model), *not* a
  latency-gated one. `.playback` = "the fast, good-enough SR tier"; `.export` =
  "the slow, best SR tier". Neither carries a realtime guarantee.
- **Ship criteria**: ADR-0006's "Throughput: parity or ≥30 fps" half is dropped;
  the C.4 verdict (ADR-0008) stands on **quality alone** — where SRVGGNet-general
  already won decisively (+26.8 VMAF), so the outcome is unchanged.

## Consequences

- **Closes the #41 throughput question** — there is no 30 fps gate to verify.
  #41's remaining content (playback *scale*: x4 shipped vs the PRD's ×2) becomes
  a pure **output-resolution/quality** choice with no latency pressure; the
  earlier "outscale=2 may miss 30 fps" worry is void. Default stays x4.
- **#40 (compression gates) is unaffected** — those gates (VMAF, compression
  savings) are quality/size, not realtime, and remain binding once NAFNet lands.
- Docs updated: `Forge-CodingPlan-v1.0.md` §4, `ForgeUpscaler-PRD-v0.2.md`,
  `Forge-BenchmarkSchema-v1.0.md` (gates §5), `ADR-0001` (gate list),
  `ForgeUpscaler.swift` tier-table comments, `CLAUDE.md`.
- The benchmark schema keeps `realtime_factor` / `fps_mean` as **informational**
  metrics — they're emitted and visible, just not gated.

## Revisit triggers

- A realtime-playback product surface is brought back **into Forge's scope**
  (rather than a separate project) → reinstate a throughput gate via a new ADR,
  sized to the actual hardware + output-resolution target.
- The separate realtime track produces a model/runtime that Forge wants to adopt
  → standard model-evaluation cycle (quality gates still apply).

## References

- [ADR-0006](0006-phase-c-unfreeze-efrlfn.md), [ADR-0008](0008-phase-c4-ab-verdict-srvggnet.md)
- C.4 real-content finding: `Docs/Benchmarks/real-signage-eval-set.md`
- Plan §4 acceptance gates: `Docs/Forge-CodingPlan-v1.0.md`
