# Step 3 (IQA-gated restoration) — findings

**Date**: 2026-05-31 · **Task**: #51 · **Status**: architecture built + tested;
gate **blocked on a learned scorer (#23)** for ship/default.

## What was built
- `NoReferenceQualityScoring` — the injected gate-signal seam (mirrors `QualityScoring`).
- `GatedRestorationProcessor` — a `FrameProcessor` decorator: runs NAFNet only when
  `quality < threshold`, else passes through. Composes where NAFNet sits today.
- `BlockinessQualityScorer` — interim, license-clean heuristic (8×8 DCT-grid edge
  energy vs interior).
- `PreprocessorFactory.makeGatedChain(...)` — **opt-in** (default path unchanged).
- `forge-quality-target --score` — decode + score a clip (threshold calibration).
- Unit tests green (synthetic blocky vs smooth; gate routing).

## Why the interim heuristic is NOT shippable (validated on real clips)
`--score`, 30-frame samples, threshold 0.6 (run restoration when mean < 0.6):

| clip | source | mean quality | gate | verdict |
|---|---|---|---|---|
| general-sports-01 | 41 Mbps clean | 0.862 | skip | ✓ |
| general-talkinghead-01 | 8.9 Mbps clean | 0.980 | skip | ✓ |
| legacy-dvd-mpeg2-02 | 0.5 Mbps degraded | 0.413 | restore | ✓ |
| general-animation-01 | 5.2 Mbps clean CGI | 0.573 | restore | ✗ false-positive |
| **Snowflake 045** | **4K @ 1.9 Mbps degraded** | **0.981** | **skip** | ✗✗ **false-negative** |

The decisive failure: **045** — the bad 4K interstitial we *visually confirmed* NAFNet
cleaned (reduced ringing) — scores 0.981 and would be **skipped**.

**Root cause:** blockiness measures energy on the **8×8 DCT grid**. Our signage degrades
as **ringing / mosquito-noise around sharp logo/text edges**, which is *not* grid-aligned,
so the metric can't see it; and sharp clean CGI edges *raise* it (false-positives). No
tuning fixes this — it's the wrong signal class for ringing-dominated content.

## Decision
- The **gating architecture is correct and stays** (seam + decorator + opt-in factory).
- **`BlockinessQualityScorer` is a baseline only** (it does catch classic DCT blocking,
  e.g. legacy DVD/MPEG-2) — **not** the ship gate signal.
- **The IQA gate requires the learned SigLIP2 NR-IQA head (#23)** before it can default-on.
  This sharpens #23 to critical-path for Step 3 (and it's the same head ImageBridge's
  no-reference still metric wants — one model unblocks both).
- Default ship path stays **unconditional NAFNet** until #23 lands and the gate is
  re-validated on real signage (incl. 045).

## Lesson (added to Conventions)
Synthetic unit tests can pass while the metric is wrong for real content. A hand-crafted
artifact proxy (blockiness) ≠ perceptual degradation; ringing-dominated signage needs a
learned NR-IQA model. **Validate any quality signal on real clean AND real degraded clips
before trusting it.**
