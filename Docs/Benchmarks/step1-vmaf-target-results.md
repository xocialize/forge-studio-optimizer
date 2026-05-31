# Step 1 — VMAF-Targeted Auto-Quality: Validation Results

**Date**: 2026-05-31 · **Tool**: `Tools/vmaf_target_search.py` · **Roadmap**: research Step 1 (#49), ADR-0013

Validates the per-title VMAF-targeting gain (research Q1) on real signage, on
**both** the ship encoder (VideoToolbox HEVC) and the measurement encoder (x264).

## Method

Sample-encode search (ab-av1 style): probe a few short ~2 s samples to find the
per-clip quality that just hits a **VMAF floor (95)**, vs a **floor-guaranteeing
flat baseline** — the single quality the *hardest* clip needs (a fixed batch
ladder must be set for the worst content; per-title saves by not over-serving the
easy clips). 6 native-4K signage clips (text → 3D → motion → people → camera).

## Results @ VMAF≥95

| encoder | per-title | floor-flat | **savings** |
|---|---|---|---|
| **VideoToolbox HEVC** (ship) | 37.2 MB | 70.4 MB (q:v 70) | **47.2%** |
| x264 (measurement) | 61.3 MB | 83.6 MB (CRF 21*) | 26.7%* |

\* the x264 run used a flat CRF 21 baseline (which happened to clear ≥95 on every
clip); the strict floor-flat is CRF 20, so the x264 figure is *conservative*.

Per-clip chosen quality spans a wide range (VT q:v **46→70**; x264 CRF **20→31**)
— the per-title signal a fixed quality cannot capture. Easy display-text gets the
cheapest setting; the banding-sensitive gradient (`layersb`) correctly gets the
most bits and sets the floor.

## Read

- **VideoToolbox HEVC's constant-quality knob works** as a CRF-equivalent
  (`-q:v` = `kVTCompressionPropertyKey_Quality`, hardware-accelerated) — the Step 0
  premise. The native `VTCompressionSession` encoder can use it directly.
- **~47% smaller than a fixed-quality batch encode at a guaranteed VMAF floor** on
  the ship encoder — the Step 1 payoff, validated on real content + the real codec.

## Framing caveats (honest)

- This is per-title vs **one flat quality for the whole batch** — the realistic
  gain over a naive pipeline. **Vimeo already does per-*title*** (a different
  setting per asset), so Forge's edge *over Vimeo specifically* is the narrower
  **VMAF-targeting refinement** (Forge hits the floor exactly; Vimeo's constant-CRF
  over-serves easy / under-serves hard — the 81–98.5 VMAF spread we measured).
- The bigger differentiators over Vimeo are **per-shot** (Step 2 — gains *within*
  an asset that Vimeo doesn't do) + NAFNet-on-degraded + HD→4K SR.
- Numbers are content-dependent; re-validate on the 30-clip royalty-free corpus
  (downloading) for a mixed-content figure.
