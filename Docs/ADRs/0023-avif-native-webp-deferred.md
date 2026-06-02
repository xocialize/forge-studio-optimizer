# ADR 0023 — Next-gen still output: AVIF via native ImageIO; WebP deferred

**Date**: 2026-06-02
**Status**: Accepted
**Driven by**: ImageBridge Phase 3 "AVIF/WebP opt-in tier"; runtime capability probe
**Depends on**: [ADR-0020](0020-still-ship-encoder.md) (still ship-encoder = ImageIO + oxipng), [ADR-0017](0017-av1-tier.md) (AV1 royalty-free premium tier — the video analog)

---

## Context

Phase 3 reserved an "AVIF/WebP opt-in tier," provisionally assuming both would need a
vendored C library (libavif+libaom / libwebp), the still analog of vendoring oxipng.

A runtime probe of `CGImageDestinationCopyTypeIdentifiers()` on the target platform
(macOS, current) changes the calculus: **`public.avif` is a natively-supported ImageIO
encode type** (macOS 13+, backed by the system AV1 encoder). `public.webp` /
`com.google.webp` are **not** present — ImageIO decodes WebP but cannot encode it.

So the two formats have very different costs, and AVIF is the one we'd pick anyway:
AV1-based, royalty-free, and generally better compression than WebP — the same reasoning
that made AV1 the premium video tier (ADR-0017), where we declined to spend on the lesser
licensed option.

## Decision

1. **AVIF ships now, natively — zero vendoring.** Add `.avif` to `StillFormat` (input) and
   `StillOutputFormat` (output); map it to `UTType("public.avif")` in `ImageIOEncoderImpl`;
   treat it as lossy (the `kCGImageDestinationLossyCompressionQuality` knob, same as
   HEIC/JPEG), so the quality-target search and the optimizer drive it unchanged. Alpha is
   carried by ImageIO. $0 SPDX — Apple framework, consistent with ADR-0020.
2. **WebP is deferred.** Encoding it requires vendoring libwebp (BSD). Given AVIF supersedes
   WebP for new content and is free here, WebP is **not** built unless a specific consumer
   surface requires WebP-out.

## Consequences

- The "AVIF/WebP opt-in tier" collapses to a few lines for AVIF + a deferral for WebP. No new
  build system, no static lib, no license surface (contrast oxipng's vendored staticlib).
- AVIF inherits the whole still pipeline for free: probe/decode round-trip, the quality-target
  floor search, the smart optimizer, and alpha.
- Platform-coupled: AVIF encode availability is ImageIO's, not ours. The `UTType("public.avif")
  ?? .heic` fallback degrades to HEIC if a future/older target lacks AVIF encode (rather than
  failing). If we ever ship on a platform without native AVIF encode, revisit (vendor libavif).

## Revisit triggers

- A consumer surface requires **WebP** output → vendor libwebp (BSD) behind the same encoder
  seam; does not change the AVIF default.
- A target platform lacks native AVIF encode → vendor libavif + an AV1 encoder (libaom/rav1e),
  or rely on the HEIC fallback.

## References

- `CGImageDestinationCopyTypeIdentifiers()` capability probe (macOS, 2026-06-02)
- [ADR-0017](0017-av1-tier.md) (royalty-free AV1 premium tier — same "don't pay for the lesser
  codec" logic), [ADR-0020](0020-still-ship-encoder.md) (ImageIO + oxipng ship encoder)
