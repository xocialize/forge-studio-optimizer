# Still quality-metric findings — ImageBridge Phase 4

Date: 2026-06-02. The still analog of `step3-iqa-gate-findings.md` — what the metric
actually does on real data, before we trust it to drive the lossy encode.

## The pipeline (Phase 4)
`StillOptimizer` (ImageBridge, metric/model-agnostic): decode → optional alpha-aware,
tiled, IQA-gated NAFNet restoration → encode. Lossy formats run a perceptual-floor
search (smallest encode clearing an **injected** `StillQualityScoring`); PNG runs the
lossless oxipng pass. `SignageStillOptimizer` (ImageBridgeForge) wires one shared
`SigLIP2NRIQAScorer` into the restoration gate and (optionally) the lossy floor.

## Finding: SigLIP2 NR-IQA is too FLAT to be a lossy-fidelity floor
Validated on a real signage frame (`clean_signage.png`, off-repo brand IP), HEIC
re-encodes scored by the SigLIP2 head:

| HEIC quality | SigLIP2 NR-IQA | bytes |
|---|---|---|
| original (PNG) | 0.910 | — |
| 1.0 | 0.910 | 519,788 |
| 0.8 | 0.908 | 101,220 |
| 0.6 | 0.908 |  79,462 |
| 0.4 | 0.903 |  51,907 |
| **search → 0.31** | **0.901** | **44,473** (**91% smaller** than q=1.0) |

The score barely moves (0.910→0.901) while bytes fall 12×. A floor of 0.85 is therefore
met at the **minimum** quality → maximal compression. The metric is also non-monotonic
near the top (q=0.8 and q=0.6 both 0.908), so fine floor-tuning is fragile.

**Why:** SigLIP2 NR-IQA is an *absolute-aesthetic / does-restoration-pay* signal
(ADR-0016) — "is this image degraded?" — not a *fidelity-vs-reference* signal. On clean,
flat signage HEIC stays "clean-looking" far down the quality knob, so the head keeps
passing. Same family as the video-side lesson: a blockiness proxy couldn't see ringing
(Conventions); validate the signal on real content before trusting it.

## Disposition
- **Plumbing**: correct + shipped. `StillOptimizer` is metric-agnostic — swapping the
  lossy floor metric is a one-liner.
- **SigLIP2 NR-IQA**: keep as the **restoration gate** (its validated job). As a lossy
  floor it behaves as "compress maximally while NR-IQA still passes" — fine for flat
  graphic/text signage (HEIC handles it cleanly, and 91% smaller at q≈0.90 is real), but
  it can NOT protect fine detail / photographic signage.
- **Recommended for fidelity-critical lossy targets**: inject a **full-reference** metric
  (SSIMULACRA2, named in ADR-0021) as the floor.

## Resolution (#71): SSIMULACRA2 full-reference floor via the reference binary
The lossy floor is **SSIMULACRA2** (libjxl / Sneyers), used at **encode time** exactly like
libvmaf on the video side — an external, accurate metric injected at the `StillQualityScoring`
seam, never linked into the bridge (ADR-0021). The official `ssimulacra2` binary ships via
`brew install jpeg-xl`, so `BinarySSIMULACRA2Scorer` shells out to it: the scores ARE the
reference (no from-scratch port to get subtly wrong). A pure-Swift port is only needed if this
ever runs **on-device**, which the encode-time quality target does not.

**Validated.** SSIMULACRA2 is monotonic where SigLIP2 was flat (synthetic detailed image:
q0.95→80.0, q0.7→75.9, q0.45→57.4, q0.2→28.2; identical≈100). On the **real** `clean_signage.png`
end-to-end (SigLIP2 gate + SSIMULACRA2 floor 90), the search picks **q=0.530, S2=89.3, 86% smaller**
than max-quality HEIC — a *principled* visually-lossless point, vs the flat SigLIP2 floor which
bottomed out at q=0.31 (91% smaller, no fidelity guard). Roles: **SigLIP2 = restoration gate**
(ADR-0016), **SSIMULACRA2 = lossy floor** (#71). Wired in `SignageStillOptimizer`.

Score scale (per the tool): 90 ≈ visually lossless at 1:1 · 70 high · 50 medium · 30 low.
