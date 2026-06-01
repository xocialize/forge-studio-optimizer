# ADR 0016 — Step 3 IQA gate ships as a scoped "restoration-pays" gate

**Date**: 2026-06-01
**Status**: Accepted
**Driven by**: Step 3 (#51) gate + the SigLIP2 NR-IQA head (#56); builds on the
Step-3 architecture (seam + decorator + opt-in factory), ADR-0010 (weights ship,
not data), and three real-content validation catches.

---

## Context

Step 3 runs NAFNet restoration **only when the input is degraded enough to benefit**.
That requires a no-reference quality signal. We rejected the interim blockiness
heuristic (wrong signal class for ringing-dominated signage) and built the learned
SigLIP2 NR-IQA head via the generate-our-own pseudo-MOS pipeline (license-clean:
our codecs + DISTS labels; no NC academic dataset — see
`Docs/Benchmarks/iqa-dataset-licensing.md`).

The **v1** head fit the synthetic labels well (val SRCC 0.82 / PLCC 0.97) but, on
real frames, scored the flagship bad files (Snowflake 045/094, 4K vector @ ~1.9 Mbps)
as clean (~0.97). Dustin chose the **data-mix iteration** path: degrade at the real
bitrates/resolutions the bad files actually have, re-train, re-eval.

## Findings (v2 — measured on real clean AND real degraded frames)

`generate_iqa_dataset.py` reworked for realism: **frame-level degradation** (degrade
the whole downscaled frame, then crop), **multi-resolution sources** (teaches the
low-res regime), heavier params (mpeg2 → 0.15 Mbps, hevc → CRF 51), resumable. New
dataset `data/iqa_ds2` (4197 tiles / 600 signage masters). v2 head: **val SRCC 0.902
/ PLCC 0.956**.

Real-frame eval (patch-mean quality; **run restoration when < ~0.78**):

| frame | v2 score | NAFNet helps? | gate |
|---|---|---|---|
| clean sports / talkinghead / signage | 0.87–0.97 | n/a | skip ✓ |
| synthetic crush (sports → crf45) | 0.66 | yes | **run ✓** |
| BAD dvd4-mpeg2 (low-res) | 0.69 / min 0.58 | yes | **run ✓** (v1 missed) |
| BAD dvd-mpeg2 (milder low-res) | 0.84 | yes | borderline skip ⚠ |
| **BAD 045 / 094 (4K vector)** | 0.95–0.97 | **~no (wash)** | skip ✓ (correct) |

Two checks reframed the 045 "failure" from a bug into correct behavior:
1. **Not a sampling miss** — at 64 random patches, 045/094 patch-**min** (0.898/0.905)
   ≈ clean_signage's (0.894). More crops never separate them.
2. **NAFNet barely moves 045** — original vs NAFNet-restored 045 scores **0.970 → 0.968**
   (a wash). Restoration on flat-vector content yields ~no perceptual delta.

So the head scores low exactly where NAFNet pays (encoded/photographic degradation)
and high where restoration is a wash (flat-vector). That is a **working
"does-restoration-pay" gate**, not a detector that "misses" 045.

## Decision

**Ship Step 3 as a scoped restoration-pays gate, default-on**, using the **v2 SigLIP2
NR-IQA head** as the `NoReferenceQualityScoring` signal, threshold **≈0.78** (run NAFNet
when mean patch quality < threshold).

- Documented scope: the gate **routes restoration to encoded/photographic degradation**
  (the cases where NAFNet measurably helps) and **correctly skips flat-vector signage**
  (045/094), where restoration is a measured wash.
- Threshold is **re-calibrated on the Swift quantized (8-bit) backbone** before
  default-on — the Python score (FP backbone) has a quantization gap (noted in
  `train_iqa_head.py`); the 0.78 operating point is the FP reference, not the ship value.
- **Revisit fine-tuning post-ImageBridge** (Dustin's call): universal bad-file detection
  / real degraded examples / NAFNet-benefit labels are **low priority**, since the
  045-class restoration is already a wash. The same head is ImageBridge's still metric —
  one model, both uses.

## Consequences

- Step 3 (#51) gate is **unblocked and default-on** (was: unconditional NAFNet until a
  learned scorer landed). The architecture (seam + `GatedRestorationProcessor` decorator
  + factory) was already correct; only the signal changes from blockiness → SigLIP2 v2.
- **Known soft edge**: the milder dvd case (0.84) skips at threshold 0.78 — acceptable for
  signage (mild degradation, modest NAFNet upside). Revisit with the post-ImageBridge mix.
- **License/security (ADR-0010)**: only the trained head ships
  (`siglip2_iqa_head.safetensors`). The dataset (`data/iqa_ds2`), eval frames
  (`data/iqa_eval_frames`, third-party brand IP), and signage masters stay gitignored /
  off-repo.
- **Lesson reinforced (3rd catch)**: strong SRCC/PLCC vs a synthetic FR label ≠ a working
  gate. Validate on real clean AND real degraded content — and check the gate decision
  correlates with the *actual* downstream benefit (here, NAFNet delta), not just a label.

## References

- `Docs/Benchmarks/step3-iqa-gate-findings.md` (full v1 + v2 eval tables)
- `Docs/Benchmarks/iqa-dataset-licensing.md` (generate-our-own rationale)
- [ADR-0010](0010-nafnet-b3-training-data.md) — weights ship, not data
- #51 (Step 3 gate), #56 (NR-IQA head), #23 (post-ImageBridge fine-tune / Plan-B)
