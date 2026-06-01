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

---

## Update (2026-06-01): trained the head — strong fit, but doesn't gate real bad files

Generate-our-own pipeline ran on the signage masters (partial: 700/1130 frames →
6,453 labeled tiles, killed mid-gen but plenty). Head trained: **val SRCC 0.823 /
PLCC 0.966** (n_val=967) vs DISTS pseudo-MOS — a strong *fit to the synthetic labels*.

**But the real-frame eval (`Scripts/eval_iqa_head.py`) is the actual gate test, and it
fails on the real bad files:**

| frame | patch-mean quality |
|---|---|
| clean masters (sports/talkinghead/signage) | 0.92–0.95 |
| synthetic crush (sports → HEVC crf45) | **0.68** ✓ detected |
| **BAD Snowflake 045 (4K@1.9 vector)** | **0.97** ✗ scored clean |
| **BAD dvd-mpeg2 (0.5 Mbps)** | 0.92 ✗ scored clean |

The head detects the degradation distribution it was TRAINED on (synthetic crush of
photographic content) but not real-source degradation that differs: 045 (flat vector +
sparse ringing — most 224 patches genuinely clean; NAFNet's benefit was modest anyway)
and dvd (320×240, out-of-distribution resolution).

**Lesson (third real-content catch):** strong SRCC/PLCC vs a synthetic FR label ≠ a
working gate. Validate the head on real clean AND real degraded frames, not just held-out
synthetic tiles.

**Path forward (iteration, not dead end) — Dustin's call:**
1. **Match the training distribution to reality** — degrade at the real bitrates/codecs/
   content-types the bad files have (4K vector @ ~1.9 Mbps, low-res MPEG-2 sources), and/or
   add real degraded examples. Re-train, re-eval on 045/dvd.
2. **Scope the gate** — accept that it detects photographic degradation (where NAFNet helps
   most) and default-skip flat/vector content (where NAFNet barely helps); validate that
   the gate decision correlates with actual NAFNet benefit.
3. The data generator + trainer + eval tooling all stand; only the training *data mix* changes.
