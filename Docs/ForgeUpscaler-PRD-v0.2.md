# ForgeUpscaler PRD v0.2

**Product**: ForgeUpscaler — Three-tier AI super-resolution for video (component of Forge)
**Owner**: Dustin / MVS Collective
**Platform**: macOS 15+ (Apple Silicon / arm64 only), tvOS companion (playback tier only)
**Framework**: Swift Package, CoreML + MLX-Swift + MetalFX
**Status**: Updated — reflects the resolved Phase C.4 A/B and ADR-0006/0007/0008
**Supersedes**: ForgeUpscaler-PRD-v0.1.md
**Last Updated**: 2026-05-29

---

## 0. Changelog from v0.1

v0.1 was a stub written before the Phase C/D decisions landed. It described
SPANV2 playback, a `themindstudio/RealESRGAN-x4plus-mlx` export port, and an
unresolved C.4 gate. **All three are now obsolete:**

| v0.1 said | v0.2 reality | Decision |
|---|---|---|
| Playback = SPANV2 (NTIRE 2026) | Playback = **SRVGGNetCompact-general x4** (MLX-Swift) | ADR-0006 dropped SPANV2 (CUDA-kernel dependency, no Metal port) → adopted EfRLFN provisionally → **ADR-0008 rejected EfRLFN** (lost C.4 A/B by −26.8 VMAF) → SRVGGNet-general |
| Export = themindstudio MLX port | Export = **Real-ESRGAN CoreML** (`realesrgan_x{2,4}.mlpackage`) | ADR-0007 (MLX repo ships a pickle `.npz` with no Swift loader) |
| C.4 gate open | C.4 **resolved** — see §4.2 | `Docs/Benchmarks/benchmark-c4-ab-v2-e06ff85.json` |

A latent defect was also fixed during C.4: the SR tile processor read the
decoder's **NV12** output as **BGRA**, shearing every frame. `MLXTileProcessor`
now normalises non-BGRA input via CoreImage. The same fix landed in the
optimizer converters. See ADR-0008.

---

## 1. Product Vision

ForgeUpscaler raises the spatial resolution of video frames with three
quality/latency tiers, all producing `CVPixelBuffer` outputs that hand off into
Forge's FFmpeg-decode → VideoToolbox-encode pipeline. Same code path also
serves Marquee Studio Pro's signage rendering.

Tiers are a **quality/cost spectrum** (fast-light → slow-heavy), **not** a
realtime guarantee — realtime SR is a separate-project concern (ADR-0009).
"Typical cost" below is informational, not a gate.

| Tier | Engine | Typical cost | Use case |
|---|---|---|---|
| `.preview` | MetalFX Spatial (no model) | very fast | Timeline scrubbing, Forge TV preview |
| `.playback` | **SRVGGNetCompact-general x4** (MLX-Swift, BSD-3-Clause) | fast, good-enough | Low-res-source → 4K enhancement |
| `.export` | **Real-ESRGAN CoreML** (RRDBNet, BSD-3-Clause) | slow, best quality | Offline export, highest quality |

---

## 2. Architecture

```
Input CVPixelBuffer (NV12 from decoder)
  └─→ ForgeUpscaler(tier:) ─→ normalize→BGRA ─→ Tile/whole-frame ─→ Model ─→ TemporalBlender? ─→ Output CVPixelBuffer
                                                                       │
                              Playback: SRVGGNetCompact-general x4 (MLX)   ← ADR-0008 (was SPANV2 → EfRLFN → SRVGGNet)
                              Export:   Real-ESRGAN CoreML (RRDBNet)       ← ADR-0007
                              Preview:  MetalFX Spatial                     (unchanged)
                              Signage:  fine-tuned SRVGGNet/Real-ESRGAN     (Phase F, optional)
```

Backend selection lives in `PlaybackUpscaler.Backend` (C.5a dual-backend
wiring); `defaultGeneral = .srvggnetGeneral(scale: 4)`. EfRLFN (`efrlfn_x{2,4}`)
remains selectable via `init(backend:)` for a future re-evaluation but is not a
default anywhere.

Shipping modules:
- `ForgeUpscaler.swift` — tier dispatcher
- `Playback/PlaybackUpscaler.swift` — backend façade (C.5a)
- `Playback/PlaybackTier.swift` — backend protocol
- `Playback/SRVGGNetCompact.swift` + `SRVGGNetCompact_Playback.swift` — shipping playback
- `Playback/EfRLFN.swift` + `EfRLFN_Playback.swift` — rejected candidate, retained
- `Playback/MLXTileProcessor.swift` — NV12→BGRA normalize + tile/whole-frame
- `Export/ExportTier.swift` + `RealESRGAN_CoreML.swift` — shipping export (ADR-0007)
- `Export/OSEDiff_MLX.swift` — stub (Phase D.3, deferred to 2026 Q3)
- `Preview/MetalFXUpscaler.swift`, `Temporal/TemporalBlender.swift` — unchanged

---

## 3. Public API

```swift
public final class ForgeUpscaler {
    public enum Tier { case preview, playback, export, signage }
    public enum ContentPreset { case general, anime, signage, dvd }
    public init(tier: Tier, preset: ContentPreset = .general, scale: Int) throws
    public func upscale(_ buffer: CVPixelBuffer) async throws -> CVPixelBuffer
}
```

`PlaybackUpscaler(scale:preset:)` routes `.anime` → SRVGGNet-anime, everything
else → SRVGGNet-general (ADR-0008). `ExportPipeline` orchestrates offline jobs.

---

## 4. Tier-Specific Requirements

### 4.1 Preview (`.preview`)
- MetalFX Spatial; < 5 ms; no quality gate. **Implemented; unchanged.**

### 4.2 Playback (`.playback`) — C.4 RESOLVED
- **Engine**: SRVGGNetCompact `realesr-general-x4v3` (MLX-Swift). Anime preset → `realesr-animevideov3`.
- **C.4 A/B result** (downscale→SR→VMAF, 30 clips, `benchmark-c4-ab-v2-e06ff85.json`):

  | Backend | mean VMAF | mean fps |
  |---|---|---|
  | **srvggnet-general-x4** | **77.96** | 102.9 |
  | srvggnet-general-wdn-x4 | 72.90 | 102.1 |
  | srvggnet-anime-x4 | 71.62 | 154.6 |
  | efrlfn-x4 | 51.12 | 94.7 |

  EfRLFN failed ADR-0006's `≥ +1.0 VMAF` criterion on all 30 clips. SRVGGNet-general adopted.
- **Quality target**: VMAF ≥ 90. Synthetic-corpus general subset was 78.1 (the harder ×4 reconstruction), but **real signage content (IBM Think 26) measured 97.8–99.7 VMAF** → met on representative content.
- **Throughput**: measured + reported (`fps_mean`), **not gated** — realtime is out of scope (ADR-0009). For reference, ~7 fps at 4K output on M-series.

### 4.3 Export (`.export`)
- **Engine**: Real-ESRGAN CoreML (`realesrgan_x{2,4}.mlpackage`, RRDBNet, BSD-3-Clause) — ADR-0007.
- 3–10 s/frame; not realtime. Tiling: fixed 128×128 input, 16 px overlap (ADR-0007 deviation from the 256/32 plan target; equivalent 1:8 ratio).
- OSEDiff (`OSEDiff_MLX`) is a throwing stub; deferred to 2026 Q3.

### 4.4 Signage (`.signage`, optional — Phase F)
- Fine-tuned SRVGGNet/Real-ESRGAN with text-aware loss (DOI 10.1016/j.patcog.2025.112869). OCR ≥ +5% vs base. **Unstarted.**

---

## 5. Out of Scope (this iteration)

- OSEDiff full implementation (D.3 stub only; revisit 2026 Q3).
- EfRLFN as a shipping default (rejected; weights retained for a possible degradation-aware re-eval — see open items).
- SPANV2 (60-day re-check cron; CUDA-kernel dependency unresolved).

---

## 6. Acceptance Criteria & Open Items

| Gate | Target | Status |
|---|---|---|
| Bundle size — ForgeUpscaler models | ≤ 90 MB | ✅ **11 MB** |
| Tier coverage smoke tests | preview + playback + export pass | ✅ ExportTierTests; playback/EfRLFN tests Xcode-only (MLX Metal) |
| Playback VMAF | ≥ 90 | ✅ **97.8–99.7 on real signage**; synthetic-corpus general 78.1 (harder ×4) |

> The former `playback_4k_fps_min ≥ 30 fps` gate is **removed (ADR-0009)** —
> realtime is a separate-project concern. Throughput is reported, not gated.

### OPEN — Playback scale (pure quality choice now)

The vendored SRVGGNet-general is **x4 only**; the PRD's "1080p → 4K" is **×2**.
**There is no native x2 SRVGGNetCompact-general weight upstream** —
`realesr-general-x4v3` is x4-baked; the upstream pattern for sub-4× output is
"run x4, then resize (`outscale<4`)". With realtime out of scope (ADR-0009) this
is now a **pure output-resolution/quality** choice — no throughput pressure:

1. **`outscale=2`** — run x4 then downscale to the ×2 target. No new weights;
   canonical upstream method. (Previously discounted for an "8K-intermediate
   may miss 30 fps" reason that no longer applies.)
2. **Train a native SRVGGNet-general x2** — lighter, but a multi-day training
   effort (no off-the-shelf weight exists).
3. **Re-scope playback to ×4** — e.g. 540p → 2160p (4K), matching realistic
   low-res UGC upscaling and the shipped weights with zero extra work.

Tracked as Task #41. Resolve before finalising the playback latency/quality numbers.

---

## 7. References

- ADR-0006 (EfRLFN adoption, reversed), ADR-0007 (export tier), ADR-0008 (C.4 verdict)
- C.4 report: `Docs/Benchmarks/benchmark-c4-ab-v2-e06ff85.json`
- Real-ESRGAN / SRVGGNetCompact: `xinntao/Real-ESRGAN` (BSD-3-Clause), release v0.2.5.0
- Text-aware SR loss: DOI 10.1016/j.patcog.2025.112869
- Superseded: ForgeUpscaler-PRD-v0.1.md
