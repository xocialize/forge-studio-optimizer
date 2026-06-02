# ADR 0022 — GIF / animated disposition: animated → MP4 (HEVC), static → PNG (lossless)

**Date**: 2026-05-31
**Status**: Accepted
**Driven by**: owner decision (2026-05-31); `Docs/ImageBridge-PRD-v0.1.md` §7 + §12
**Depends on**: [ADR-0013](0013-videotoolbox-first-ship-encoder.md) (MP4/HEVC ship encoder), [ADR-0020](0020-still-ship-encoder.md) (PNG/oxipng lossless), [ADR-0019](0019-imagebridge-sibling-package.md) (the bridge handoff)

---

## Context

GIF is two formats wearing one extension: a single-frame still and a multi-frame animation.
They want different optimal targets, and the PRD left the default disposition open (§12).
The owner's decision resolves it:

- **Animated GIF → MP4.** A multi-frame GIF is a tiny, palette-limited video; the right
  modern target is the ship video encoder, not an optimized GIF.
- **Static (single-frame) GIF → PNG.** A one-frame GIF is a ≤256-color still; PNG is lossless
  for it and, after oxipng, typically smaller — with proper alpha instead of GIF's 1-bit
  transparency key.

This also pins the single legitimate coupling point between the two packages (ADR-0019): the
animated path is exactly where `ImageBridge` hands off to `FormatBridge`.

## Decision

**Classify by frame count at probe time; route accordingly.**

1. **Probe disposition.** `StillMediaProbing` reports `frameCount`. `frameCount == 1` ⇒
   **static**; `frameCount > 1` ⇒ **animated**. (Same rule covers APNG and multi-frame TIFF.)
2. **Static GIF → PNG (lossless).** Decode via ImageIO → optional `FrameProcessor` →
   encode PNG → oxipng (ADR-0020). GIF transparency key maps to PNG alpha. Lossless: pixels
   preserved.
3. **Animated GIF → MP4.** Decode the frame sequence (ImageIO frame enumeration, honoring
   per-frame delays) → run the **same per-frame `FrameProcessor`** → **hand the sequence to
   `FormatBridge`** for encode to **MP4 / HEVC default, H.264 fallback** (ADR-0013). The
   animated path's output is a `FormatBridge` deliverable; `ImageBridge` does not re-implement
   video muxing.
4. **No optimized-GIF target ships.** "Re-optimize as GIF" / "animated WebP" / "APNG for
   animation" are explicitly **not** the default (may return as opt-in later if a consumer
   needs GIF-in/GIF-out).

## Consequences

- **Reuses both ship encoders, adds none.** Static → ADR-0020 PNG path; animated → ADR-0013
  MP4 path. The only new code is the **classification + the sequence handoff** to FormatBridge.
- **`ImageBridge` → `FormatBridge` dependency is now load-bearing for the animated path**
  (consistent with ADR-0019's "they meet at sequences"). The static path keeps **no**
  FormatBridge/FFmpeg dependency.
- **Two GIF-animation semantics are lost crossing to MP4 — flag to the pipeline consumer:**
  - **Alpha.** GIF supports 1-bit transparency; the MP4/HEVC ship path is opaque. Animated
    transparent GIFs must be **flattened against a matte** (default: white or a
    caller-supplied background) before encode. True animated alpha is out of the ship path
    (would need HEVC-with-alpha / ProRes 4444 / AV1-alpha — an opt-in, not the default).
  - **Loop.** GIFs loop infinitely by default; MP4 carries no loop semantic. **The consumer
    (e.g. Marquee playback) must set looping**; the file itself won't.
- **Tiny/degenerate animations.** A 2-frame GIF still routes to MP4 by the rule. That's
  acceptable (HEVC handles short clips fine), but expose a `minAnimatedFrames` threshold so a
  caller can force the static→PNG path for pathological cases if needed.
- **Frame timing.** GIF per-frame delays are variable; map them to a constant frame rate (or
  VFR if the consumer supports it) at handoff. Default: derive a CFR from the modal delay and
  document the rounding.

## Revisit triggers

- A pipeline consumer requires GIF-in/GIF-out (compatibility surface) → add an opt-in
  optimized-GIF / animated-WebP target; does not change the default.
- A surface needs animated transparency → add an opt-in alpha-preserving video target
  (HEVC-with-alpha / ProRes 4444 / AV1), gated like the other opt-in tiers.

## References

- `Docs/ImageBridge-PRD-v0.1.md` §7, §12
- [ADR-0013](0013-videotoolbox-first-ship-encoder.md), [ADR-0019](0019-imagebridge-sibling-package.md), [ADR-0020](0020-still-ship-encoder.md)
