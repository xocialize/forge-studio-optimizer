# ImageBridge — PRD v0.1 (seed)

**Status**: Draft for review — forward-looking reference, not authoritative.
**Owner**: Dustin / MVS Collective
**Umbrella**: ForgeStudio (companion to `forge-studio-optimizer`)
**Platform**: macOS 15+ (Apple Silicon arm64 only). Non-realtime, quality-first.

## 1. Thesis

A still image is a **one-frame video at the `CVPixelBuffer` layer**. ForgeOptimizer's
entire AI chain — `NAFNetProcessor`, the SR tiers, the SigLIP2 IQA head — conforms to
`FrameProcessor` (`process(CVPixelBuffer) -> CVPixelBuffer`) and has **no format
knowledge**. It is reused *unchanged* for images.

Therefore ImageBridge is almost entirely **I/O boundary work** plus a still-image analog
of `QualityTargetSearch`. We do **not** rebuild optimization; we feed the existing chain.

```
ImageBridge ──→ ForgeOptimizer (FrameProcessor)          [reused unchanged]
      └──→ ImageIO / PDFKit (decode + native encode)     [new, native]
      └──→ vendored oxipng / libavif / libwebp           [new, opt-in tiers]
      └──→ FormatBridge                                   [animated/sequence handoff]
```

## 2. Why a sibling package, not an extension of FormatBridge

FormatBridge is the **FFmpeg-decode + VideoToolbox-encode** engine. Routing stills
through it is the wrong tool:

- **Native is higher quality for stills.** `CGImageSource`/`CGImageDestination` (ImageIO)
  give hardware HEVC stills (HEIC), proper chroma control, and color management.
- **Stills carry data the video path discards.** Alpha, ICC profiles, EXIF/orientation,
  DPI. The video pipeline is opaque YUV (NV12) by design. We must *preserve* these.
- **Clean reuse, not entanglement.** ImageBridge mirrors FormatBridge's public-protocol /
  internal-impl seam and reuses the `FrameProcessor` injection point verbatim. The two
  packages meet only at the **animated/multi-frame handoff** (§7).

`ImageBridge` depends on `ForgeOptimizer` (for the `FrameProcessor` it injects) and,
optionally, on `FormatBridge` for the sequence path. It does **not** depend on FFmpegXC.

## 3. Decode boundary (Source → `[CVPixelBuffer]` + sidecar metadata)

| Input | Path | Notes |
|---|---|---|
| PNG / JPEG / TIFF / HEIC / BMP / single-frame GIF | `CGImageSource` (ImageIO) | Preserves ICC, bit depth, alpha. Honor EXIF orientation on read. |
| PDF (per page) | PDFKit / CoreGraphics rasterize at target DPI | Reuses the pptx→PDF→PNG approach already built. Multi-page → frame sequence. |
| Animated GIF / multi-frame TIFF / APNG | `CGImageSource` frame enumeration | → sequence path (§7). |
| SVG / vector | **Out of scope v1.** | If needed later: `resvg` (MPL-2.0, permissive) — **not** librsvg (LGPL/GPL). |

Decoder output is `[CVPixelBuffer]` (count 1 for stills) plus a `StillMetadata` sidecar
(format, dimensions, bit depth, alpha mode, ICC, DPI, EXIF, frame count/delays).

## 4. The two hazards that carry over from CLAUDE.md (read before coding)

1. **Alpha is the real new problem.** NAFNet and the SR models were trained on **opaque
   RGB**. Stills routinely carry alpha (PNG/TIFF/GIF transparency). The orchestrator must
   **unassociate (un-premultiply) → run RGB through the `FrameProcessor` → recombine
   alpha**. Process or pass-through alpha as a separate single channel; never feed a
   premultiplied RGBA buffer straight into a model trained on opaque frames. (This is the
   natural seam to later borrow ForgeAlpha's matting.)

2. **The fp16 global-pool overflow is *worse* for stills.** CLAUDE.md §Conventions: NAFNet
   SCA's global spatial mean overflows fp16's ~65504 ceiling at ≥540×960 → NaN. A 300-DPI
   PDF page or a 6000×4000 TIFF dwarfs 4K, so **tiling is mandatory** on the still path and
   the **fp32 global-pool** fix is non-negotiable. Reuse `MLXTileProcessor` from
   ForgeUpscaler rather than inventing a tiler.

   Note the inverse of the NV12 hazard: ImageIO hands you **BGRA/RGBA**, *not* NV12 — so do
   **not** apply the `ensureBGRA()` NV12 assumption to stills. The still decoder is already
   in a packed RGB space; route it accordingly.

## 5. Encode boundary — tiers (mirrors the encoder ADRs)

**Ship tier (native, zero license risk) — the analog of ADR-0013 VideoToolbox-first:**
- **HEIC** (hardware HEVC stills) — best quality/size for photographic content.
- **JPEG** (ImageIO, native chroma control) — interchange.
- **PNG** (ImageIO baseline) — then handed to the lossless optimizer below.
- **TIFF** — lossless interchange / archival.
All via `CGImageDestination`. Apple system frameworks ⇒ no SPDX exposure.

**Lossless PNG optimization — the direct answer to the pngcrush ask:**
- **oxipng (MIT, lossless PNG/APNG).** This is the "pngcrush but keeps quality" answer:
  lossless re-compression *mathematically* preserves pixels, so the quality concern
  disappears by construction. Vendor it like FFmpegXC — either the CLI or the Rust lib via
  a small C shim (`imagequant-sys`-style). Use `--strip safe` only when the caller opts to
  drop metadata.
- **Lossy palette quantization (pngquant / libimagequant) is GATED OUT of ship builds.**
  Verified: libimagequant v4 is **GPL-v3-or-commercial** and the upstream license text
  explicitly names *App Store distribution* as requiring the commercial license. Under the
  existing `.permissiveOnly` `LicensePolicy`, it cannot ship. Treat it exactly like
  SVT-AV1/x264 today: **opt-in / conditional only**, never in the default ship path. If a
  permissive lossy-palette path is wanted later, evaluate a from-scratch median-cut /
  k-means quantizer in MLX (you already have the GPU plumbing).

**Next-gen opt-in tier (vendored permissive) — analog of the conditional AV1/x264 tier:**
- **AVIF** via libavif + rav1e/aom (BSD/MIT).
- **WebP** via libwebp (BSD).
- ImageIO *can* encode AVIF/WebP on recent macOS but support is version-dependent and
  partial; vendored libs are the reliable path and keep parity with the FFmpegXC pattern.

## 6. Quality-targeted optimization — the crown-jewel reuse

The video side binary-searches the VideoToolbox quality knob to hit a **VMAF floor**
(`QualityTargetSearch` + `VideoToolboxQualityTargetEncoder`, with the metric injected via
`QualityScoring` so FormatBridge never links libvmaf). Mirror this exactly:

- **`StillQualityTargetSearch`** — binary-searches the still encoder's quality parameter
  (JPEG/HEIC/AVIF/WebP quality 0–100) for the smallest file clearing a perceptual floor.
- **Metric seam (`StillQualityScoring`)** — injected from the runner, *not* linked into the
  bridge (same separation as libvmaf). VMAF is a video metric; for stills use:
  - **SSIMULACRA2** (modern perceptual still metric; `ssimulacra2` Rust crate, BSD-3,
    vendors cleanly) — the recommended default reference metric, **or**
  - the **SigLIP2 NR-IQA head** already queued in `ForgeOptimizer/QualityRegressor` for a
    **no-reference** floor (no original needed — ideal when the "original" is itself
    degraded signage).
- Compose via `makeQualityTargetEncoder(scorer:search:)`, identical shape to FormatBridge.

This is where "leverage the video optimization for post-conversion" becomes literal: same
search architecture, same injection seam, swap VMAF→SSIMULACRA2/IQA and the VT quality
knob→the still encoder quality knob.

## 7. Animated / multi-page — the FormatBridge handoff

Frame sequences (animated GIF, multi-frame TIFF, APNG, multi-page PDF) run the **same
per-frame `FrameProcessor`**, then choose an assembly target:

| Source | Output options |
|---|---|
| Animated GIF | optimized GIF (lossless), animated WebP, APNG (oxipng), or **transcode to HEVC/AV1 via FormatBridge** (best compression — this is the bridge case). |
| Multi-page PDF | per-page optimized images, or re-imposed optimized PDF (PDFKit write). |
| Multi-frame TIFF | per-frame still outputs or a single optimized container. |

For video-target assembly, **reuse FormatBridge's sequence/encode plumbing** — do not
duplicate it. This is the one place the two packages legitimately couple.

## 8. Public surface (mirror `FormatBridgeFactory`)

```swift
public enum ImageBridgeFactory {
    static func initialize(logLevel: LogLevel)
    static func makeProbe() -> any StillMediaProbing            // format, dims, depth, alpha, ICC, DPI, frameCount
    static func makeDecoder() -> any StillDecoding              // URL -> [CVPixelBuffer] + StillMetadata
    static func makeEncoder() -> any StillEncoding              // (CVPixelBuffer, StillEncoderSettings) -> file
    static func makeQualityTargetEncoder(
        scorer: any StillQualityScoring,
        search: StillQualityTargetSearch
    ) -> StillQualityTargetEncoder                              // still analog of the VMAF-target encoder
    static func makeOrchestrator(
        frameProcessor: (any FrameProcessor)? = nil             // pass ForgeOptimizer.ModelChain UNCHANGED
    ) -> any StillConversionOrchestrating
}
```

New models/enums: `StillFormat`, `StillOutputFormat`, `AlphaMode` (`.none`/`.straight`/
`.premultiplied`), `ColorModel`, `StillEncoderSettings` (format, quality, strip-metadata,
target-floor). **Reuse** `OptimizationLevel`, `ProcessorRole`, `QualityPreset`,
`ResolutionMode`, `ColorSpaceInfo` from FormatBridge's `Enums.swift` rather than redefining.

## 9. Metadata + color management (new vs. video)

- **Preserve** ICC, EXIF/orientation, DPI by default; expose an explicit `--strip` opt-out
  (oxipng `--strip safe|all`).
- **Pin the working space.** The AI processors operate in a working RGB space; pin it
  (source ICC or sRGB), run, then **tag output** — directly analogous to the BT.709 pinning
  lesson in CLAUDE.md (untagged output ⇒ players/viewers guess ⇒ saturated-color drift).
- **Look at output pixels.** Same discipline as the NV12 SSIM=1.0 tautology bug: validate a
  real high-res image with alpha and a wide-gamut ICC, not just an opaque sRGB test tile.

## 10. Phasing

1. **Phase 1 — skeleton + native I/O.** `ImageBridge` package, ImageIO decode/encode
   (HEIC/JPEG/PNG/TIFF), `StillMediaProbing`, orchestrator with `FrameProcessor`
   passthrough, **tiling wired** (fp16/global-pool/large-res). No new models. Parity test:
   decode→encode round-trip preserves ICC + alpha; processor passthrough is a no-op at
   `.off`.
2. **Phase 2 — the keep-quality ask.** Vendor oxipng (lossless PNG/APNG) +
   `StillQualityTargetSearch` + SSIMULACRA2 scorer seam. Gate lossy quant OUT.
3. **Phase 3 — formats + animation.** AVIF/WebP opt-in tier; animated GIF/APNG; multi-page
   PDF; alpha-aware split/recombine.
4. **Phase 4 — IQA-gated optimization.** Wire the SigLIP2 NR-IQA head as a no-reference
   floor (depends on the QualityRegressor training already queued in ForgeOptimizer).

## 11. Proposed ADRs (to mint alongside, in repo style)

- **ADR-0016** — ImageBridge as a sibling package (native ImageIO/PDFKit), not a FormatBridge
  extension. Rationale §2.
- **ADR-0017** — Still ship-encoder = ImageIO (native HEIC/JPEG/PNG/TIFF) + oxipng (MIT,
  lossless). Lossy palette quant (libimagequant/pngquant, GPL-or-commercial) is conditional/
  opt-in only, excluded from `.permissiveOnly` builds. Rationale §5.
- **ADR-0018** — Still quality-target search reuses the FormatBridge `scorer`/`search`
  injection shape; metric = SSIMULACRA2 (full-ref) or SigLIP2 NR-IQA (no-ref), never linked
  into the bridge. Rationale §6.

## 12. Open decisions (need your call)

- **Default reference metric:** SSIMULACRA2 (full-ref, needs the pre-degradation original)
  vs. SigLIP2 NR-IQA (no-ref, works on already-degraded signage). For the signage corpus the
  "original" is often itself degraded — NR-IQA may be the more honest floor. Which is the v1
  default?
- **Animated-GIF default target:** keep-as-GIF (compatibility) vs. transcode-to-HEVC/AV1
  (compression). Pipeline consumer decides — what does Marquee actually ingest?
- **oxipng integration:** vendored CLI (fast to land, matches FFmpegXC pattern) vs. static
  lib via C shim (cleaner, no subprocess). Recommend CLI for Phase 2, lib later.
