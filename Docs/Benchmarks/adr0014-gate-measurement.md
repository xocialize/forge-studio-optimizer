# ADR-0014 compression gate — first measurement

**Date**: 2026-05-31
**Tool**: `Tools/quality_target_gate.py` over `forge-quality-target` (Step 1)
**Subset**: high-bitrate (≥8 Mbps) progressive masters in the royalty-free corpus —
`general-sports-01` (41 Mbps), `general-sports-02` (11 Mbps),
`general-talkinghead-01` (8.9 Mbps). 120-frame samples, target VMAF≥95.

## Method (per ADR-0014)

Per-title VMAF-target each clip → quality `q_i`, size `s_i`. The flat
floor-guaranteeing baseline is `Q_flat = max(q_i)` (one quality that guarantees
the floor on every clip). Encode each clip flat at `Q_flat` → `b_i`. Gate metric
`compression_quality_target = 1 − Σs_i / Σb_i`.

## Result

| clip | targeted q | targeted VMAF | targeted MB | flat MB (@0.719) | per-clip saving |
|---|---|---|---|---|---|
| sports-01 | 0.663 | 94.67 | 11.98 | 16.33 | **26.6%** |
| sports-02 | 0.719 | 96.19 | 6.46 | 6.46 | 0% (is the baseline) |
| talkinghead-01 | 0.719 | 95.35 | 3.45 | 3.45 | 0% (is the baseline) |
| **total** | | worst 94.67 | **21.88** | **26.23** | **16.6%** |

- **`compression_quality_target` = 16.6% smaller than flat** → **FAIL** vs ADR-0014's
  suggested ≥30%.
- **`vmaf_target_floor` = worst 94.67 ≥ 94.5** → **PASS** (quality is honest).

## Reading

- The **16.6% is real and defensible** — it matches the literature's ~20% per-title
  win at constant quality (Netflix). ADR-0014's **30% was optimistic** for the
  *vs-flat* metric.
- It's diluted by the subset: **2 of 3 clips ARE the flat baseline** (q=0.719), so
  they contribute 0 saving; only sports-01 has headroom below the flat quality. A
  **larger, more quality-diverse high-bitrate subset** (or the real proprietary
  masters) would raise the aggregate.
- The impressive **63%** figure (Step 1 validation) is **savings vs SOURCE**, not vs
  the flat baseline — a different, product-facing claim. ADR-0014 deliberately
  chose vs-flat to avoid source-bitrate dependence, at the cost of a smaller number.

## Open decision (needs Dustin)

The gate as written fails. Options:
1. **Calibrate the threshold to ~15%** (realistic for per-title-vs-flat; matches the
   literature). Smallest change; revise ADR-0014's suggested X.
2. **Gate on savings-vs-source** (≥X% smaller than the high-bitrate source, e.g.
   ≥40%) — impressive (63% here) but reintroduces source-bitrate dependence (the
   reason it's restricted to the high-bitrate subset).
3. **Expand the high-bitrate subset** for more quality diversity before fixing a
   threshold (the 3-clip committable subset is thin; real masters are proprietary).

Until decided, the **measurement + tooling are in place** (`--fixed`/`--json` on
the encoder, `quality_target_gate.py`); wiring the chosen metric into
`GateEvaluator` is the remaining step.
