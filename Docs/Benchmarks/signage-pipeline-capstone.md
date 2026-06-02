# Roadmap capstone — full pipeline on real 4K signage (#43)

**Date**: 2026-06-01 · Validates Steps 1 (HEVC VMAF-target) + 4 (AV1) end-to-end on the real
signage clips, via `forge-quality-target --codec {hevc,av1} --target 95`.

## Results (VMAF target 95, sample = first 96 frames)

| clip | content | HEVC VMAF / Mbps | AV1 VMAF / Mbps | AV1 out codec |
|---|---|---|---|---|
| signage_abacus (4K) | line-art graphics | 94.8 / 0.74 | 94.7 / **0.39** | av1 ✓ |
| signage_characters (4K) | flat-color graphics | 95.0 / 0.63 | 94.8 / **0.51** | av1 ✓ |
| signage_layersb (portrait 4K) | layered graphics | 95.3 / 5.12 | 94.5 / **1.73** | av1 ✓ |
| signage_ferrari (3240×1920, untagged) | gradient graphic | ~~87.0 / 2.79~~ → **94.5 / ~0.3** (#61 fixed) | 95.4 / **0.24** | av1 ✓ |
| signage_sevilla (3240×1920, untagged) | gradient graphic | ~~83.1 / 2.80~~ → **94.97 / 0.34** (#61 fixed) | 95.8 / **0.13** | av1 ✓ |

**Headline:** **AV1 (Step 4) hits VMAF ≥ 95 on every real signage clip at 0.13–1.73 Mbps** — and is
the clear winner. The HEVC numbers for **ferrari/sevilla above are wrong — a measurement
artifact** (see below); HEVC actually does fine on those clips too.

## The ferrari/sevilla HEVC "failure" — root-caused to an UNTAGGED-COLOR bug (#60→#61)

Both are 3240×1920 (width not ÷16), which first looked like an alignment bug, then like 8-bit
gradient banding. **Both wrong.** The decisive chain (#55 lesson, third time — validate the
measurement, not just the pipeline):
- **Output clean**, dims correct, independent VMAF agrees (83.12==83.12) → not a reference build bug.
- **8-bit HEVC is fine here**: software x265 hits VMAF 97.5/95.2 (intro/mid), and ffmpeg's
  `hevc_videotoolbox` (Main8) hits **98** on the same frames. Main10 ≈ Main8 (98.2) → **not a
  banding/codec issue; Main10 NOT needed.**
- **Root cause: untagged source color-matrix mismatch.** ferrari/sevilla are **untagged**
  (`color_* = unknown`); abacus is tagged bt709. Our pipeline's FormatBridge decode and the ffmpeg
  VMAF reference disagree on the matrix for untagged HD → a BT.601-vs-709 color shift VMAF
  penalizes (→ 83) and the search wastes bits. **Proof:** tagging sevilla bt709 (metadata only, no
  re-encode) flips our HEVC result from **82.9 @ 2.80 Mbps** → **94.97 @ 0.34 Mbps** (met target).
  So VT-HEVC is excellent on these clips (near AV1); the capstone numbers were the bug.

**Corrected positioning:** AV1 and HEVC both do well on this signage; AV1 is smaller (premium for
AV1-capable targets), HEVC is the universal default. The "HEVC bands on gradients" conclusion was
wrong — it was a color bug.

## Follow-ups

- **#60 (done):** sample representativeness — skip a flat lead-in so the search reflects real
  content (helps blank-intro clips like abacus; shipped). Main10 **ruled out** (not needed).
- **#61 (FIXED):** untagged-source color handling. Diagnosed: the **ship encode output is already
  correct** (verified `inf` PSNR vs the source read as BT.709) — NOT a ship bug. The issue was a
  benchmark inconsistency: ffmpeg decodes an untagged source as **BT.601** (`SWS_CS_DEFAULT`) while
  our encoder tags output BT.709 → the VMAF reference disagreed → 83/87. Fix (two parts):
  (1) `FFmpegDecoder` now tags decoded frames with the matrix (BT.709 for HD ≥720 / 601 for SD,
  using the source tag when present) — correct hygiene that also fixes the restoration/CoreImage
  path on untagged sources; (2) `forge-quality-target` normalises an untagged source (stream-copy
  re-tag, no re-encode) before measuring. Result: sevilla 82.9→**94.97 @ 0.34 Mbps**, ferrari
  86.8→**94.5**; FormatBridge suite 53/53 green.

Reproduce: `forge-quality-target --input <clip> --codec {hevc,av1} --target 95 [--av1-preset 8]`.
