> **⚠️ SUPERSEDED by [ForgeUpscaler-PRD-v0.2.md](ForgeUpscaler-PRD-v0.2.md) (2026-05-29).**
> v0.1's SPANV2 playback + themindstudio-MLX export + open C.4 gate are all
> obsolete: playback ships SRVGGNetCompact-general (ADR-0008), export ships
> Real-ESRGAN CoreML (ADR-0007). Kept for history only.

# ForgeUpscaler PRD v0.1

**Product**: ForgeUpscaler — Three-tier AI super-resolution for video (component of Forge)
**Owner**: Dustin / MVS Collective
**Platform**: macOS 15+ (Apple Silicon / arm64 only), tvOS companion (playback tier only)
**Framework**: Swift Package, CoreML + MLX-Swift + MetalFX
**Status**: Draft — synthesized from existing scaffold + 2026 Q2 refresh coding plan
**Last Updated**: 2026-05-26

---

## 0. Document Status

This is a v0.1 stub PRD. The full ForgeUpscaler PRD referenced by Forge-CodingPlan-v1.0.md never landed on this dev machine. This document is reconstructed from:

- The existing scaffold in `Packages/ForgeUpscaler/Sources/ForgeUpscaler/` (Playback, Export, Preview, Temporal modules already present)
- The intent captured in `Forge-PRD-v0.3.md` §10 and §13
- The 2026 Q2 refresh changes specified in `Docs/Forge-CodingPlan-v1.0.md` Phases C, D, F
- The original ForgeUpscaler comment header in `ForgeUpscaler.swift` (tier table)

Refine in place; do not treat as authoritative beyond the existing code surface.

---

## 1. Product Vision

ForgeUpscaler raises the spatial resolution of video frames with three quality/latency tiers, all of which produce `CVPixelBuffer` outputs and hand off cleanly into Forge's existing FFmpeg decode → VideoToolbox encode pipeline. Same code path also serves Marquee Studio Pro's signage rendering.

| Tier | Engine | Target latency | Use case |
|---|---|---|---|
| `.preview` | MetalFX Spatial | < 5 ms | Timeline scrubbing, Forge TV preview enhancement |
| `.playback` | SPANV2 (CoreML/MLX) | < 33 ms (30 fps) | Real-time 1080p → 4K, Apple TV 4K, Forge live preview |
| `.export` | Real-ESRGAN MLX port | 3–10 s/frame | Offline export, highest quality |

The playback tier was previously SRVGGNetCompact; the 2026 Q2 refresh swaps it for SPANV2 (NTIRE 2026 ESR winner) if the C.4 decision gate passes. The export tier was an in-house RRDBNet port; the refresh adopts the existing `themindstudio/RealESRGAN-x4plus-mlx` (BSD-3-Clause) instead of porting from scratch.

---

## 2. Architecture

```
Input CVPixelBuffer ──┐
                      ├─→ ForgeUpscaler(tier:) ──→ TileProcessor ──→ Model ──→ TemporalBlender? ──→ Output CVPixelBuffer
                      │                              │
                      │                              └─ 256×256 tiles, 32px overlap, linear blend
                      │
                  Playback: SPANV2 (was SRVGGNetCompact)
                  Export:   Real-ESRGAN MLX (was in-house RRDBNet)
                  Preview:  MetalFX Spatial (unchanged)
                  Signage:  Fine-tuned SPANV2/Real-ESRGAN (Phase F, optional)
```

Existing scaffold maps to:

- `Sources/ForgeUpscaler/ForgeUpscaler.swift` — public entry; tier dispatcher
- `Sources/ForgeUpscaler/Playback/PlaybackUpscaler.swift` — currently SRVGGNetCompact; Phase C target
- `Sources/ForgeUpscaler/Playback/TileProcessor.swift` — tile inference + blending
- `Sources/ForgeUpscaler/Export/ExportUpscaler.swift` — currently RRDBNet; Phase D target
- `Sources/ForgeUpscaler/Export/ExportPipeline.swift` — decode → SR → encode orchestrator
- `Sources/ForgeUpscaler/Preview/MetalFXUpscaler.swift` — unchanged
- `Sources/ForgeUpscaler/Temporal/TemporalBlender.swift` — EMA + flow-guided warping; unchanged

New modules added by the refresh:

- `Sources/ForgeUpscaler/Playback/SPANV2.swift` (Phase C.2)
- `Sources/ForgeUpscaler/Export/RealESRGAN_MLX.swift` (Phase D.1)
- `Sources/ForgeUpscaler/Export/OSEDiff_MLX.swift` — stub only (Phase D.3)
- `Sources/ForgeUpscaler/Signage/` (Phase F)

---

## 3. Public API (current + planned)

```swift
public final class ForgeUpscaler {
    public enum Tier { case preview, playback, export, signage }
    public enum Preset { case general, anime, signage }

    public init(tier: Tier, preset: Preset = .general, scale: Int) throws

    public func upscale(_ buffer: CVPixelBuffer) async throws -> CVPixelBuffer
    public func upscaleSequence(_ buffers: [CVPixelBuffer]) async throws -> [CVPixelBuffer]
}
```

`ExportPipeline` remains the orchestrator for offline jobs; receives `Tier.export`, drives FFmpeg decode + VideoToolbox encode, reports `ExportProgress`.

Phase F adds `Tier.signage` and text-aware fine-tuned weights for both playback and export. Inference path is identical to `.playback`/`.export`; weights differ.

---

## 4. Tier-Specific Requirements

### 4.1 Preview (`.preview`)
- **Engine**: MetalFX Spatial Scaler — no learned model
- **Latency**: < 5 ms on M4 Pro
- **Quality target**: Acceptable for scrubbing; no quality gate
- **Status**: Implemented; unchanged

### 4.2 Playback (`.playback`)
- **Engine**: SPANV2 (Phase C target) or SRVGGNetCompact (current fallback)
- **Latency**: ≥ 30 fps at 1080p → 4K on M4 Pro and Apple TV 4K (2nd gen+)
- **Quality target**: VMAF ≥ 90 on `general` 10-clip subset
- **Decision gate**: C.4 — adopt SPANV2 only if throughput ≥ 1.2× SRVGGNetCompact at equal-or-better VMAF
- **Weights**: Pending NTIRE 2026 ESR release; fallback ladder PDS → PKDSR → from-scratch training

### 4.3 Export (`.export`)
- **Engine**: Real-ESRGAN MLX (`themindstudio/RealESRGAN-x4plus-mlx`, BSD-3-Clause)
- **Latency**: 3–10 s/frame on M4 Pro at 1080p → 4K; not realtime
- **Quality target**: Output matches PyTorch reference within LPIPS 0.01
- **Tiling**: 256×256 input, 32 px overlap, linear blending; arbitrary input resolutions
- **Bonus**: `com.xocialize.coreml/models/macos/realesrgan_x{2,4}.mlpackage` already exists — Phase D will compare CoreML wrapper vs the MLX port and pick

### 4.4 Signage (`.signage`, optional — Phase F)
- **Engine**: SPANV2 or Real-ESRGAN with character-prior + word-length loss fine-tune
- **Quality target**: ≥ +5% OCR accuracy on rendered signage clips vs base SPANV2/Real-ESRGAN
- **Training-only loss term**: Nie et al. Pattern Recognition vol. 173 (DOI 10.1016/j.patcog.2025.112869)

---

## 5. Out of Scope (this iteration)

- OSEDiff full implementation (D.3 stub only; defer until DiffusionKit's SD 2.1 path matures, est. 2026 Q3)
- Real-ESRGAN-Anime variant (use general weights for now)
- SeedVR2 and NTIRE 2026 UGC VR winners (too heavy for Apple Silicon today)
- Any 8K output (4K cap until M5 Max benchmarks land)

---

## 6. Acceptance Criteria

Pipeline-level gates from `Forge-CodingPlan-v1.0.md` §4 that touch ForgeUpscaler:

| Gate | Target | Where measured |
|---|---|---|
| `playback_4k_fps_min` | ≥ 30 fps at 1080p → 4K on M4 Pro | ForgeUpscaler benchmark, general subset |
| Tier coverage | preview + playback + export all pass smoke tests | Tests/ForgeUpscalerTests |
| Bundle size — ForgeUpscaler models | ≤ 90 MB total | `du Packages/ForgeUpscaler/Resources/` |

---

## 7. References

- Forge-PRD-v0.3.md §3, §10, §13
- Forge-CodingPlan-v1.0.md Phases C, D, F
- Forge-BenchmarkSchema-v1.0.md (ForgeUpscalerResults, UpscalerRun, TextMetrics)
- SPANV2 / NTIRE 2026 ESR — arXiv:2604.03198
- Real-ESRGAN MLX — `huggingface.co/themindstudio/RealESRGAN-x4plus-mlx` (BSD-3-Clause)
- Text-aware SR loss — DOI 10.1016/j.patcog.2025.112869

---

End of v0.1 stub.
