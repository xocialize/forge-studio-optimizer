# ADR 0017 — Still ship-encoder: ImageIO native + oxipng lossless; lossy palette quant gated out

**Date**: 2026-05-31
**Status**: Proposed
**Driven by**: `Docs/ImageBridge-PRD-v0.1.md` §5
**Mirrors**: [ADR-0013](0013-videotoolbox-first-ship-encoder.md) (VideoToolbox-first ship encoder)
**Governed by**: ForgeOptimizer `ModelRegistry/LicensePolicy` (`.permissiveOnly`)

---

## Context

The companion converter must "optimize" stills the way the video side optimizes video —
**smaller at quality**. The motivating reference (PNGcrush / pngquant family) does aggressive
PNG optimization but the *lossy* members of that family **do not preserve pixels**, which is
the wrong default for a quality-first product. Two questions: which encoders ship, and which
are license-clean under the existing `.permissiveOnly` policy.

- **The quality loss in the pngcrush family comes from lossy palette quantization**, not
  from re-compression. Lossless re-compression (DEFLATE strategy search, filter selection,
  bit-depth reduction *that is exact*) preserves pixels by construction.
- **Apple's ImageIO is the still analog of VideoToolbox**: native, hardware HEVC stills
  (HEIC), color-managed, $0 SPDX exposure — exactly the ADR-0013 reasoning applied to images.
- **The best lossy palette quantizer (libimagequant / pngquant) is GPL-or-commercial.**
  Verified 2026-05-31: libimagequant v4 is **GPL-v3-or-later or a paid commercial license**,
  and upstream's own license text **explicitly names App Store distribution** as requiring
  the commercial license. Under `.permissiveOnly` it cannot ship — same bucket as SVT-AV1 and
  licensed x264 (ADR-0013 §3–4).
- **oxipng is MIT** (verified 2026-05-31), lossless PNG/APNG, multithreaded, available as a
  Rust library or CLI — vendorable the way FFmpegXC vendors its libs.

## Decision

**Ship a native ImageIO core plus a lossless oxipng tier. Gate lossy palette quantization
out of `.permissiveOnly` builds.**

1. **Ship tier — ImageIO (native, license-clean):**
   - **HEIC** (hardware HEVC stills) — efficient default for photographic content.
   - **JPEG** (native chroma control) — interchange.
   - **PNG** (baseline) — then handed to the lossless optimizer below.
   - **TIFF** — lossless interchange / archival.
   All via `CGImageDestination`. Apple system frameworks ⇒ no SPDX obligation.
2. **Lossless PNG optimization tier — oxipng (MIT):** the "keep quality" answer. Lossless
   re-compression mathematically preserves pixels, so the quality concern is void by
   construction. `--strip safe` only when the caller opts to drop metadata.
3. **Lossy palette quantization (libimagequant/pngquant) = conditional / opt-in only**,
   **never** in the default ship path and **excluded from `.permissiveOnly` builds** —
   treated identically to SVT-AV1 / licensed x264. A `LicensePolicy` check enforces this at
   the registry boundary, not by convention.
4. **Next-gen opt-in tier — vendored permissive:** AVIF (libavif + rav1e/aom, BSD/MIT) and
   WebP (libwebp, BSD), opt-in/build-selected. ImageIO can encode AVIF/WebP on recent macOS
   but support is version-dependent and partial, so vendored libs are the reliable path and
   keep parity with the FFmpegXC pattern.

The shipped binary's default still path calls **ImageIO + oxipng only** — no GPL code, no
paid-license code.

## Consequences

- **"Keep quality" is satisfied by definition**, not by tuning: the default optimizer is
  lossless. Lossy gains are available but require an explicit, license-aware opt-in.
- **The `.permissiveOnly` gate does real work here.** A naive "just link pngquant for better
  PNGs" would silently put a GPL/commercial obligation into an App Store binary. The policy
  check blocks that at build/registry time.
- **A permissive lossy path is a future option, not a dependency.** If lossy palette
  reduction is wanted in ship builds later, evaluate a from-scratch median-cut / k-means
  quantizer in MLX (the GPU plumbing already exists) rather than licensing libimagequant.
- **oxipng integration choice is deferred to the implementer** (PRD §12): vendored CLI
  (fast, matches FFmpegXC) vs. static lib via C shim (no subprocess). Recommend CLI for
  Phase 2, lib later.
- **HEIC patent posture mirrors ADR-0013**: don't overstate "HEIC is clean" to clients;
  content-side HEVC patent pools sit with the signage operator, not the tool.

## Revisit triggers

- A ship-blocking format gap in ImageIO (e.g. a required input ImageIO can't read) →
  evaluate a vendored permissive decoder; does not change the *encode* decision.
- libimagequant relicenses to a permissive license → re-evaluate the lossy default (unlikely;
  the commercial license is the maintainer's business model).

## References

- `Docs/ImageBridge-PRD-v0.1.md` §5
- libimagequant license: pngquant.org/lib (GPL-v3-or-commercial, App Store named); oxipng: MIT
- [ADR-0013](0013-videotoolbox-first-ship-encoder.md), [ADR-0002](0002-dev-vs-runtime-ffmpeg-split.md)
- [ADR-0016](0016-imagebridge-sibling-package.md), [ADR-0018](0018-still-quality-target-search.md)
