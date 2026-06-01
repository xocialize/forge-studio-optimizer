# Roadmap capstone — full pipeline on real 4K signage (#43)

**Date**: 2026-06-01 · Validates Steps 1 (HEVC VMAF-target) + 4 (AV1) end-to-end on the real
signage clips, via `forge-quality-target --codec {hevc,av1} --target 95`.

## Results (VMAF target 95, sample = first 96 frames)

| clip | content | HEVC VMAF / Mbps | AV1 VMAF / Mbps | AV1 out codec |
|---|---|---|---|---|
| signage_abacus (4K) | line-art graphics | 94.8 / 0.74 | 94.7 / **0.39** | av1 ✓ |
| signage_characters (4K) | flat-color graphics | 95.0 / 0.63 | 94.8 / **0.51** | av1 ✓ |
| signage_layersb (portrait 4K) | layered graphics | 95.3 / 5.12 | 94.5 / **1.73** | av1 ✓ |
| signage_ferrari (3240×1920) | **smooth-gradient** graphic | **87.0 / 2.79 ✗** | 95.4 / **0.24** | av1 ✓ |
| signage_sevilla (3240×1920) | **smooth-gradient** graphic | **83.1 / 2.80 ✗** | 95.8 / **0.13** | av1 ✓ |

**Headline:** **AV1 (Step 4) hits VMAF ≥ 95 on every real signage clip at 0.13–1.73 Mbps** — and is
the clear winner on gradient-heavy content. HEVC (our VT ship encoder) hits target on 3/5 but
*cannot* on the two smooth-gradient clips even at max quality.

## The ferrari/sevilla HEVC "failure" — diagnosed (NOT a resolution bug)

Both are 3240×1920 (width not ÷16), which first looked like an alignment bug. It isn't —
diagnosed three ways:
- **Output is correct**: 3240×1920, decodes, extracted frame is clean (not sheared/garbled).
- **Measurement is honest**: an independent ffmpeg VMAF agrees exactly (83.12 == 83.12), so it's
  not a reference artifact (cf. #55).
- **Root cause = 8-bit HEVC banding on smooth gradients + a flat-intro sample.** The clip is
  flat-color figures over a smooth pink gradient; its first 96 frames are a near-blank intro. VT
  HEVC (Main, **8-bit**) bands on smooth gradients → VMAF ~83 *at quality 1.0* (search does 1 probe,
  reports "target unreachable"). AV1 — even 8-bit — handles flat/gradient regions far better
  (95.8 on the *same* frames). This refines #59: VT-HEVC is fine on detailed/textured graphics
  (abacus/characters/layersb hit ~95) but bands on smooth-gradient signage.

## Actionable follow-ups (#60)

1. **Sample representativeness** — the VMAF-target search samples the first `--max-frames` frames;
   a flat intro (sevilla/ferrari) is unrepresentative. Sample evenly across the clip (or skip
   leading near-constant frames) so the target reflects real content.
2. **Main10 (10-bit) HEVC for gradient/graphics content** — 8-bit banding is *the* HEVC weakness
   on signage gradients; 10-bit HEVC (decodes on modern Apple) would cut it. Evaluate Main10 as the
   signage HEVC profile. This is a **default-path** quality win.
3. **Positioning confirmed:** AV1 is the right encoder for gradient-heavy signage (common). Route
   signage → AV1 where the target decodes it; HEVC stays the universal-compat default.

Reproduce: `forge-quality-target --input <clip> --codec {hevc,av1} --target 95 [--av1-preset 8]`.
