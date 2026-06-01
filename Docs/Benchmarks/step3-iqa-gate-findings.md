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

---

## Update (2026-06-01b): data-mix iteration done → it's a working **"restoration-pays" gate**

Dustin chose path 1 (data-mix iteration). Implemented in `generate_iqa_dataset.py`:
- **Frame-level degradation** (`--frame-level`): degrade the *whole* (downscaled) frame, then
  crop — matches how real low-bitrate encodes actually look (v1 degraded 224 *crops* at a CRF,
  which doesn't reproduce frame-wide bitrate starvation).
- **Multi-resolution sources** (`MULTI_RES_LONG_SIDES`): downscale to varied long-sides so the
  head sees low-res content (the dvd 320×240 regime v1 never trained on).
- **Heavier params**: mpeg2 down to 0.15 Mbps, hevc to CRF 51.
- **Resumable** (`--resume`, per-tile flush) so a kill never loses progress.
- **Bug caught mid-run:** multi-res produced *odd* dimensions → every hevc/av1/mpeg2 degrade
  silently threw → low-res sources kept only `noise` (exactly backwards). Fixed: force even dims
  (`_even()` crop). Verified 0 codec failures, 7.0 tiles/src, all 4 codecs balanced.

New dataset `data/iqa_ds2`: **4197 tiles / 600 signage masters**. DISTS labels compress into
**[0.44, 1.0]** (DISTS distance rarely exceeds ~0.5 in practice). v2 head: **val SRCC 0.902 /
PLCC 0.956**.

**Real-frame eval (patch-mean, the actual gate test):**

| frame | v1 | **v2** | NAFNet helps? | gate verdict |
|---|---|---|---|---|
| clean sports / talkinghead / signage | 0.92–0.95 | 0.87–0.97 | n/a | skip ✓ |
| synthetic crush (sports→crf45) | 0.68 | **0.66** | yes | **run ✓** |
| BAD dvd4-mpeg2 (low-res) | (missed) | **0.69 / min 0.58** | yes | **run ✓ (v1 missed)** |
| BAD dvd-mpeg2 (milder low-res) | 0.92 | 0.84 | yes | borderline skip ⚠ |
| **BAD 045 / 094 (4K vector)** | 0.97 | 0.95–0.97 | **~no (wash)** | skip ✓ (correct) |

**Two checks that reframed the 045 "failure":**
1. **Not a sampling miss** — at 64 random patches, 045/094 patch-**min** = 0.898/0.905 ≈
   clean_signage's 0.894. More crops don't separate them; the head genuinely sees them as clean.
2. **NAFNet barely moves 045** — scoring original vs NAFNet-restored 045: patch-mean
   **0.970 → 0.968** (a wash). Restoration on flat-vector files produces ~no perceptual delta,
   corroborating "NAFNet's benefit was modest anyway" on 045.

**Conclusion:** the v2 head is a **working "does-restoration-pay" gate**: it scores low exactly
where NAFNet helps (encoded/photographic: crush 0.66, dvd4 0.58) and high where restoration is a
measurable wash (flat-vector 045/094). The original "045 = false-negative" framing was wrong —
skipping 045 is *correct*. Clean operating point at **patch-mean ≈ 0.78** (run < 0.78).

**Decision (Dustin, 2026-06-01):** ship the scoped gate for digital signage as-is; **revisit
fine-tuning post-ImageBridge** (universal detection / real degraded examples / NAFNet-benefit
labels — low priority, since the 045-class restoration is already a wash). Known soft edge: the
milder dvd case (0.84) skips — acceptable for signage. See ADR-0016.

Artifacts (off-repo, weights ship per ADR-0010): head `data/iqa_head2/siglip2_iqa_head.safetensors`
(val SRCC 0.902), dataset `data/iqa_ds2/` (gitignored), eval frames `data/iqa_eval_frames/`.
