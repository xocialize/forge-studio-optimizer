# ADR 0019 — ImageBridge as a sibling package (native ImageIO/PDFKit), not a FormatBridge extension

**Date**: 2026-05-31
**Status**: Accepted (implemented ImageBridge Phase 1/2, 2026-06-01)
**Driven by**: `Docs/ImageBridge-PRD-v0.1.md` §2
**Relates to**: [ADR-0013](0013-videotoolbox-first-ship-encoder.md) (ship-encoder strategy this mirrors)

---

## Context

The ForgeStudio pipeline needs a companion still-image converter/optimizer (TIFF, GIF,
PDF, PNG, JPEG, HEIC). The temptation is to extend `FormatBridge` — it already decodes and
encodes pixels. But `FormatBridge` is specifically the **FFmpeg-decode + VideoToolbox-encode
video engine**, and stills are a poor fit for it:

- **The optimizer is already format-blind.** ForgeOptimizer's AI chain conforms to
  `FrameProcessor` (`process(CVPixelBuffer) -> CVPixelBuffer`) and carries no format
  knowledge. `NAFNetProcessor`, the SR tiers, and the (pending) SigLIP2 IQA head operate on
  `CVPixelBuffer` and **reuse unchanged** for stills. A still is a one-frame `CVPixelBuffer`.
- **Native I/O is higher quality for stills.** `CGImageSource` / `CGImageDestination`
  (ImageIO) give hardware HEVC stills (HEIC), color-managed read/write, and per-format
  chroma control. PDFKit/CoreGraphics rasterize PDF pages (the pptx→PDF→PNG path already
  built). FFmpeg's still handling is strictly worse and pulls the whole C decode stack in.
- **Stills carry data the video path deletes by design.** Alpha, ICC profiles,
  EXIF/orientation, DPI. `FormatBridge` is opaque YUV (NV12) end-to-end. Bolting metadata
  preservation onto it would distort a clean engine.
- **Licensing stays clean.** ImageIO/PDFKit are Apple system frameworks — no SPDX exposure,
  no FFmpegXC dependency on the still path.

The two engines genuinely meet at exactly one point: **animated / multi-frame sources**
(animated GIF, multi-frame TIFF, APNG, multi-page PDF), which are frame sequences. That
handoff is covered by [ADR-0022](0022-gif-and-animated-disposition.md).

## Decision

**Build `ImageBridge` as a sibling package, not an extension of `FormatBridge`.**

1. **Mirror the FormatBridge seam.** `ImageBridge` exposes a public-protocol surface
   (`StillMediaProbing`, `StillDecoding`, `StillEncoding`, `StillConversionOrchestrating`)
   with internal-only implementations, fronted by an `ImageBridgeFactory` shaped exactly
   like `FormatBridgeFactory`.
2. **Reuse the `FrameProcessor` injection verbatim.** `ImageBridgeFactory.makeOrchestrator(
   frameProcessor:)` accepts ForgeOptimizer's `ModelChain` **unchanged** — the AI pipeline
   is injected, never reimplemented.
3. **Native I/O.** Decode via ImageIO (`CGImageSource`) + PDFKit/CoreGraphics; encode via
   ImageIO (`CGImageDestination`). No FFmpeg on the still path.
4. **Reuse shared models.** `ImageBridge` reuses `OptimizationLevel`, `ProcessorRole`,
   `QualityPreset`, `ResolutionMode`, `ColorSpaceInfo`, `LogLevel` from FormatBridge's
   `Enums.swift` rather than redefining them.

**Dependency stack:**

```
ImageBridge ──→ ForgeOptimizer (FrameProcessor)        [reused unchanged]
      └──→ ImageIO / PDFKit                            [native decode + encode]
      └──→ FormatBridge                                [animated/sequence handoff only — ADR-0022]
```

`ImageBridge` does **not** depend on FFmpegXC.

## Consequences

- **Zero new optimizer code.** NAFNet/SR/IQA carry over by construction; the AI work is
  already done. The package is I/O + a quality-target search ([ADR-0021](0021-still-quality-target-search.md)).
- **Two video-path lessons port directly and are *load-bearing* for stills:**
  - **fp16 global-pool overflow (CLAUDE.md §Conventions).** NAFNet SCA's global spatial
    mean overflows fp16 at ≥540×960. Stills (a 300-DPI PDF page, a 6000×4000 TIFF) dwarf
    4K, so **tiling is mandatory** — reuse `MLXTileProcessor` from ForgeUpscaler — and the
    **fp32 global-pool** fix is required, not optional.
  - **The NV12 hazard is *inverted*.** ImageIO hands packed BGRA/RGBA, **not** NV12. Do
    **not** apply the `ensureBGRA()` NV12 assumption to stills; the still decoder is already
    in a packed RGB space.
- **Alpha is a genuinely new concern.** The models trained on opaque RGB. The orchestrator
  must unassociate alpha → process RGB → recombine (PRD §4). This is the natural seam to
  later borrow ForgeAlpha matting.
- **Color management is new.** ICC/EXIF/DPI must round-trip by default; pin the working RGB
  space and tag output — the still analog of the BT.709 pinning lesson (ADR-0013 context).
- **Future extraction.** If a third consumer ever needs the `FrameProcessor` seam, both
  bridges already isolate it cleanly; no extraction is forced now.

## Revisit triggers

- A consumer needs FFmpeg-only still formats ImageIO can't read (rare; e.g. exotic camera
  RAW not covered by ImageIO) → add a narrow FFmpeg decode adapter behind `StillDecoding`,
  still inside ImageBridge, without collapsing the packages.

## References

- `Docs/ImageBridge-PRD-v0.1.md`
- [ADR-0013](0013-videotoolbox-first-ship-encoder.md), [ADR-0011](0011-xcodebuild-for-mlx-inference.md)
- [ADR-0020](0020-still-ship-encoder.md), [ADR-0021](0021-still-quality-target-search.md), [ADR-0022](0022-gif-and-animated-disposition.md)
