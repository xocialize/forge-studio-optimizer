# ADR 0014 — Revise the §4 compression gate (proposed)

**Date**: 2026-05-31
**Status**: Accepted (2026-05-31 — Dustin: "go with the recommended approach; metrics can always be re-generated")
**Supersedes**: the §4 fixed-CRF compression gate; refines [ADR-0012](0012-compression-savings-crf-vs-source.md)
**Driven by**: #40 finish + `Docs/Research/forge-studio-encoding-strategy-v2.md` + ADR-0013

---

## Context

Finishing #40 (validate the §4 compression gates — `compression_balanced_min`
≥35% @Balanced, `compression_signage_max_min` ≥55% @Maximum) surfaced two reasons
the gate as defined is no longer the right test:

1. **"Savings vs source" needs bitrate headroom.** The royalty-free corpus spans
   **52 kbps → 41 Mbps** source bitrates — the `screencapture` clips are already
   ~50–100 kbps, so re-encoding *grows* the file (negative savings). A mean
   savings-vs-source gate over a mixed-bitrate corpus is unmeasurable: it
   penalizes Forge for clips that had nothing to save. Savings-vs-source only
   means something on **high-bitrate masters** (the real product input).
2. **The encoder + method pivoted** (ADR-0013): the gate was written for
   fixed-CRF x264; the ship path is **VideoToolbox HEVC + VMAF-targeted**
   per-title (and per-shot) rate control.

The compression **capability is validated** on representative high-bitrate
content: signage masters **62.6% smaller @ VMAF 98.74** (fixed CRF, ADR-0012),
and **47% smaller at a guaranteed VMAF≥95** via VMAF-targeting on VideoToolbox
HEVC (`Docs/Benchmarks/step1-vmaf-target-results.md`).

## Decision (proposed)

Replace the fixed-CRF savings-vs-source gate with a **VMAF-targeted gate measured
on high-bitrate sources**, on the ship encoder:

- **`compression_quality_target`** — at a target VMAF (start 95; 93 for the
  "smaller" tier), the per-title VMAF-targeted encode (VideoToolbox HEVC) must be
  **≥X% smaller than the floor-guaranteeing flat-quality baseline** on a
  **high-bitrate** corpus subset (sources ≥ ~8 Mbps, i.e. true masters). Excludes
  already-compressed clips by source-bitrate threshold, not by category.
  **X CALIBRATED to ≥15%** (2026-05-31, Dustin): the first real measurement on the
  3-clip ≥8 Mbps subset gave **16.6% vs flat** — in line with the literature's
  ~20% per-title win. The earlier "~47%/63%" figures were savings **vs source** (a
  different, product-facing claim), not vs the flat baseline; the vs-flat metric is
  source-independent (better as a CI regression guard) but smaller, so 30% was
  optimistic. The 63%-vs-source remains the headline product number. See
  `Docs/Benchmarks/adr0014-gate-measurement.md`.
- **`vmaf_target_floor`** — the targeted encodes must actually hit the VMAF floor
  (mean ≥ target − slack), i.e. quality is guaranteed, savings are honest.
- Keep `bundle_size_max`; retire `compression_balanced_min` /
  `compression_signage_max_min` (fixed-CRF, mixed-corpus) once the above land.

Rationale: this measures the *product claim* ("smaller at a guaranteed quality")
on inputs where it's meaningful, on the encoder we ship, using the method we ship.

## Consequences

- Needs the **native VideoToolbox encoder** (Step 0, #48) wired into the
  benchmark, + the VMAF-targeted search (Step 1, #49, prototyped). Until then,
  the validated prototype numbers stand in for the gate.
- The benchmark corpus needs a **high-bitrate subset tag** (or a source-bitrate
  filter) so the savings gate runs only where headroom exists.
- #40's *capability* question is answered (yes); the gate *definition* is the open
  item this ADR resolves.
- The `--crf` measurement path (ADR-0012) + the plumbing fixes (skip postProcess,
  empty-subset N/A, committed) remain useful for measurement/regression.

## Open question for Dustin

Adopt this revision (VMAF-targeted gate on high-bitrate sources), or keep the
original fixed-CRF gate and instead just **filter the corpus to high-bitrate
clips** for the existing gate? The former aligns with the shipped strategy; the
latter is a smaller change but keeps a fixed-CRF metric we're moving away from.

## References

- `Docs/Benchmarks/step1-vmaf-target-results.md`, `Docs/Benchmarks/vimeo-method-analysis.md`
- [ADR-0012](0012-compression-savings-crf-vs-source.md), [ADR-0013](0013-videotoolbox-first-ship-encoder.md)
