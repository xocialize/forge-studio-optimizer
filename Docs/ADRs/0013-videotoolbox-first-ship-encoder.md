# ADR 0013 — VideoToolbox-first ship encoder (HEVC default / H.264 fallback)

**Date**: 2026-05-31
**Status**: Accepted
**Amends**: [ADR-0002](0002-dev-vs-runtime-ffmpeg-split.md) (dev-vs-runtime ffmpeg split)
**Driven by**: `Docs/Research/forge-studio-encoding-strategy-v2.md` (deep-research Q1–Q4)

---

## Context

Forge serves an **Apple-first client base with an iPhone-8 (A11) playback floor**,
with the ability to host multiple renditions and **build-select by player**. The
deep-research report evaluated the ship-encoder choice against this base and the
licensing/hardware landscape:

- **iPhone 8 (A11) decodes HEVC in hardware** — so HEVC is a safe efficient default
  across the entire Apple client range; **AV1 is the only codec the floor cannot
  decode** (needs A17 Pro / M3+).
- **Apple's VideoToolbox** uses the platform-licensed OS encoder on the dedicated
  hardware media-encode block: **$0 codec licensing** (no x264 GPL obligation, no
  encoder-side H.264/HEVC patent royalty for Forge), **constant encode cost across
  chip tiers** (the M1 floor encodes fast/cool where x264 `slow`/`veryslow`
  software encoding struggles most), and **no ffmpeg/x264 dependency in the shipped
  binary** (simpler notarization, smaller app).
- **x264** is GPL (our shipped FFmpeg build excludes it, ADR-0002); shipping it in
  a proprietary app needs a commercial x264 license + a Via LA H.264 license. Its
  edge is a **finer CRF knob + clean-content micro-levers** (`--tune animation`,
  DCT-decimation off, psy-rd).
- **VideoToolbox's quality knob is coarser** than x264 CRF and lacks those levers,
  so it captures *most but not all* of the per-shot rate-control upside.

## Decision

**Ship on Apple VideoToolbox.**

1. **`VideoToolbox HEVC`** = the efficient Apple-native **default** (hardware
   decode from the iPhone-8 floor up).
2. **`VideoToolbox H.264`** = the universal-compatibility **fallback**.
3. **AV1 (SVT-AV1)** = an **opt-in, build-selected export tier** for AV1-decode-
   capable endpoints (A17 Pro / M3+), never the floor default. (ADR pending when
   built — research Step 4.)
4. **Licensed x264** = a **conditional quality-premium path**, adopted *only* if
   A/B testing on our corpus shows VideoToolbox's coarser rate control leaves
   meaningful quality-per-bit on the table at our VMAF targets (research Step 5).

The shipped binary calls VideoToolbox (`VTCompressionSession` via FormatBridge's
encoder) — **no ffmpeg/x264 at runtime**.

## Amendment to ADR-0002

ADR-0002 split ffmpeg into a dev toolchain vs a LGPL runtime. **Runtime encode now
moves off ffmpeg entirely onto VideoToolbox.** ffmpeg + `libx264` + `libvmaf`
remain a **dev/measurement** toolchain only — the benchmark runner's `--crf`
compression pass (ADR-0012) and the VMAF-targeted quality search (research Step 1)
use ffmpeg/x264/libvmaf to *measure* and *prototype*; they are not in the product.
(The libvmaf LGPL-v3 entanglement stays contained to the dev path.)

## Consequences

- **Rate control is encoder-agnostic and ports cleanly.** The research's highest-ROI
  work — VMAF-targeted, per-shot quality search (Steps 1–2) — wraps a sample-encode
  search around *whatever* encoder's quality knob. Prototype on ffmpeg/x264 CRF
  now (fast iteration, no Apple-API binding), then bind to the VideoToolbox quality
  parameter for ship. So this decision does **not** block Step 1/2.
- **#40's x264 CRF numbers stay valid** as a measurement/baseline; the *ship*
  encoder is independent of the measurement encoder.
- **FormatBridge encoder** → VideoToolbox `VTCompressionSession` (HEVC/H.264),
  quality-targeted; this supersedes the pending #33 "migrate to NativeEncoder" with
  a VideoToolbox target.
- **Coarser-knob caveat is bounded**; the x264-premium path (Step 5) is the
  decision-gated escape hatch, not assumed.
- **Re-verify at ship time**: per-device decode support, 10-bit/HDR assumptions
  (we target 8-bit Main unless decided otherwise), HEVC content-side patent pools
  (Via LA / Access Advance / Avanci) sit with the signage operator, not the tool —
  don't overstate "HEVC is clean" to clients (research §Q4 licensing).

## References

- `Docs/Research/forge-studio-encoding-strategy-v2.md` §Q4 + Recommendations Step 0
- [ADR-0002](0002-dev-vs-runtime-ffmpeg-split.md), [ADR-0009](0009-drop-realtime-requirements.md),
  [ADR-0012](0012-compression-savings-crf-vs-source.md)
