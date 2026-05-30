# ForgeUpscaler Bundled Models — Provenance & License

This directory holds three model families:

1. **Real-ESRGAN CoreML** (`realesrgan_x{2,4}.mlpackage`) — export tier, vendored
   from `xocialize-code/com.xocialize.coreml`.
2. **EfRLFN safetensors** (`efrlfn_x{2,4}.safetensors`) — playback tier
   candidate, converted from the upstream MIT-licensed PyTorch checkpoint by
   `Packages/ForgeTraining/Scripts/convert_efrlfn_to_mlx.py`. See
   [ADR-0006](../../../../Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md).
3. **SRVGGNetCompact safetensors** (`realesr_{general,general_wdn,anime}_x4.safetensors`) —
   playback tier baseline, converted from xinntao/Real-ESRGAN's `v0.2.5.0` BSD-3-Clause
   PyTorch checkpoints by `Packages/ForgeTraining/Scripts/convert_srvggnet_to_mlx.py`.
   The Phase C.4 A/B baseline EfRLFN must beat per ADR-0006 ship criterion.

## Vendored files

These `.mlpackage` files are vendored from [xocialize-code/com.xocialize.coreml](https://github.com/xocialize-code/com.xocialize.coreml) at commit **`3989123`** (`models/macos/`).

| Model | Architecture | Task | Input → Output | Size | SPDX |
|---|---|---|---|---|---|
| `realesrgan_x2.mlpackage` | RRDBNet | 2× upscaling (export) | RGB 128×128 → RGB 256×256 | 1.2 MB | `BSD-3-Clause` |
| `realesrgan_x4.mlpackage` | RRDBNet | 4× upscaling (export) | RGB 128×128 → RGB 512×512 | 2.4 MB | `BSD-3-Clause` |
| `efrlfn_x2.safetensors`   | EfRLFN (ECA+tanh) | 2× upscaling (playback candidate) | RGB NHWC `[0,1]` → 2× NHWC | 956 KB (FP16) | `MIT` |
| `efrlfn_x4.safetensors`   | EfRLFN (ECA+tanh) | 4× upscaling (playback candidate) | RGB NHWC `[0,1]` → 4× NHWC | 989 KB (FP16) | `MIT` |
| `realesr_general_x4.safetensors` | SRVGGNetCompact 64×32+PReLU | 4× upscaling, general (playback baseline) | RGB NHWC `[0,1]` → 4× NHWC | 2.4 MB (FP16) | `BSD-3-Clause` |
| `realesr_general_wdn_x4.safetensors` | SRVGGNetCompact 64×32+PReLU | 4× + WDN denoise (playback baseline) | RGB NHWC `[0,1]` → 4× NHWC | 2.4 MB (FP16) | `BSD-3-Clause` |
| `realesr_anime_x4.safetensors` | SRVGGNetCompact 64×16+PReLU | 4× upscaling, anime video (real-time) | RGB NHWC `[0,1]` → 4× NHWC | 1.2 MB (FP16) | `BSD-3-Clause` |

**Total**: ~11.5 MB

SHA pins and source URLs for the SRVGGNetCompact variants live in [`../../../LICENSES.md` §1B](../../../LICENSES.md); xinntao release `v0.2.5.0` is the canonical upstream.

## Wiring status

**In use as of 2026-05-27 (Phase D, ADR-0007)** — backs `ForgeUpscaler.RealESRGAN_CoreML` (`Sources/ForgeUpscaler/Export/RealESRGAN_CoreML.swift`), the concrete `ExportTier` conformer used by `ExportUpscaler` for the export (offline, max-quality) path.

The Phase D evaluation between these mlpackages and the [`themindstudio/RealESRGAN-x4plus-mlx`](https://huggingface.co/themindstudio/RealESRGAN-x4plus-mlx) MLX port resolved in favour of the CoreML mlpackages because the upstream MLX repo ships an `.npz` pickle with no Swift loader, no safetensors equivalent, and no `config.json`. See [ADR-0007](../../../../Docs/ADRs/0007-real-esrgan-export-tier.md) for the full rationale and revisit triggers.

### Resolved — SRVGGNet vendor (Task #28)

The previous "Outstanding gap" note in this section read: *"PlaybackUpscaler.swift still expects model names `SRVGGNet_general_x{2,4}` and `SRVGGNet_anime_x4`; none of those mlpackages exist in `com.xocialize.coreml` or this repo's vendored set."* Task #28 resolved this by vendoring the three upstream SRVGGNetCompact variants from xinntao/Real-ESRGAN as MLX safetensors (rows 5-7 of the table above). The Swift module is at `Sources/ForgeUpscaler/Playback/SRVGGNetCompact.swift` (Task #28). Phase C.5 will wire `PlaybackUpscaler.swift` to load via the new MLX path once Phase C.4 A/B picks a winner.

The original PlaybackUpscaler.swift naming convention (`SRVGGNet_general_x{2,4}`, `SRVGGNet_anime_x4`) does not map directly to upstream filenames; per investigation 2026-05-28, "SRVGGNetCompact" is the architectural backbone xinntao uses for `realesr-general-x4v3` (general) and `realesr-animevideov3` (anime). No native SRVGGNet x2 variant ships; x4 with `outscale<4` is the upstream pattern.

## Provenance

Real-ESRGAN upstream: [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN), BSD-3-Clause. Trained weights converted to CoreML in [com.xocialize.coreml](https://github.com/xocialize-code/com.xocialize.coreml). The CoreML conversion preserves the BSD-3-Clause license. Apps embedding ForgeUpscaler must surface the BSD-3-Clause attribution in their licenses UI — see [LICENSES.md §1B](../../../LICENSES.md) for the exact text.

## Tile shape

The mlpackages are compiled with a fixed `[1, 3, 128, 128]` input shape. `RealESRGAN_CoreML` reports `inputTileSize = 128, tileOverlap = 16` to match — the same shape `PlaybackUpscaler` uses for the SRVGGNet path. The plan §D.2's "256×256 tile / 32 px overlap" target assumed a flexible-input MLX backend; ADR-0007 documents the deviation. Effective seam quality is equivalent (both shapes give a 1:8 overlap ratio under linear blending in `TileProcessor`).

## Deployment target

macOS 15.0+. iOS variants exist at `com.xocialize.coreml/models/ios/realesrgan_x{2,4}.mlpackage` if needed.

## EfRLFN safetensors (playback tier candidate)

Converted from the upstream PyTorch checkpoints at
[github.com/EvgeneyBogatyrev/EfRLFN](https://github.com/EvgeneyBogatyrev/EfRLFN)
(`README` §"Model Weights" → Google Drive). Conversion script:
`Packages/ForgeTraining/Scripts/convert_efrlfn_to_mlx.py` (Phase C.3 / Task #20).

### Provenance — upstream `.pt`

| Scale | Google Drive ID                      | SHA-256 of `.pt`                                                   | Params  |
| ----- | ------------------------------------ | ------------------------------------------------------------------ | ------- |
| 2     | `1VeoW94hN1X-8kxGXQSyR53YzRqF1htKQ`  | `fbfd1bb37973d2b8b53493c5b91c0ef106f74d200115250a8a025b8e6a121cb3` | 487,010 |
| 4     | `1vJgrsz62IAMeS9i2ChDhQGO6UO1ZUXhr`  | `56a43a1071c447083f236a91e145b909d1a33beaeb0fc6ddf9f1c88b71620e1c` | 503,894 |

### Provenance — converted safetensors

Both files were produced at FP16 from the SHA-pinned upstream `.pt` listed
above, with the converter's PyTorch→MLX key remap (`upsampler.0.*` →
`upsampler.conv.*`) and Conv2d/Conv1d transposes:

| File                       | SHA-256                                                          |
| -------------------------- | ---------------------------------------------------------------- |
| `efrlfn_x2.safetensors`    | `929563c8cd24730dadf3575757203a1f0a3f6e4776e65c8b417adcf34feb209d` |
| `efrlfn_x4.safetensors`    | `79ceb8d18514ed1bb6997e6d71723f085b1b60333d7f21689f1e0e75ef24a1fe` |

The MLX-Python reference model parity at FP16:

| Scale | Full-pass `max_abs` (synthetic seed) | Full-pass `max_abs` (real checkpoint) |
| ----- | ------------------------------------ | ------------------------------------- |
| 2     | < 1e-5                               | 4.07e-4                               |
| 4     | < 1e-5                               | 4.52e-4                               |

Both pass the Coding Plan §C.3 target of `max_abs < 1e-2` for full-pass FP16
parity; the FP32 reference parity is < 1e-5 across all six ERLFB blocks (see
`Packages/ForgeTraining/Python/tests/test_efrlfn_parity.py`).

### License

The upstream weights are MIT-licensed per the EfRLFN repository's
[LICENSE](https://github.com/EvgeneyBogatyrev/EfRLFN/blob/main/LICENSE). The
weights were trained on **StreamSR**, a 5,200-video YouTube-derived dataset;
the architecture-port + load path inherits the MIT terms cleanly, but any
**retraining** on derivative data is blocked on the legal review captured as
Task #19 in [ADR-0006 §"StreamSR data provenance"](../../../../Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md). See
[LICENSES.md §1A](../../../LICENSES.md) for the YouTube-ToS / training-data
note that applies here.

### Wiring status — not yet wired

As of 2026-05-27 (Phase C.3 landing), the converted safetensors are vendored
but the playback tier still routes through SRVGGNetCompact. Phase C.4 (Task
#21) performs the A/B and decides whether EfRLFN replaces SRVGGNetCompact;
Phase C.5 wires it if so. See
[ADR-0006 §"Ship criterion"](../../../../Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md).

### Resolved — Swift `pixelShuffleNHWC` channel ordering (post-Task #18 patch)

The MLX-Python parity work surfaced a channel-ordering discrepancy in the
Swift port's `pixelShuffleNHWC` helper (`EfRLFN.swift` ~L201–217). The
original C.2 implementation reshaped channels as `(r, r, C)`; PyTorch's
`nn.PixelShuffle` uses `(C, r, r)`, and the upstream weights are calibrated
for `(C, r, r)`. Symptom was max_abs ≈ 2.27 at the upsampler in Phase C.3
parity tests vs ≈ 1e-6 for the verified MLX-Python reference at
`Packages/ForgeTraining/Python/models/efrlfn_mlx.py::_pixel_shuffle_nhwc`.

**Patched 2026-05-27** in the same commit that landed C.3:
- `Packages/ForgeUpscaler/Sources/ForgeUpscaler/Playback/EfRLFN.swift`
  reshape now uses `[N, H, W, C, r, r]` + transpose `(0, 1, 4, 2, 5, 3)`
- `Packages/ForgeOptimizer/Sources/ForgeOptimizer/Restoration/NAFNet.swift`
  had the same buggy helper from B.1 — fixed proactively even though
  NAFNet weights aren't trained yet (would have surfaced at B.4 / B.5)

Phase C.4 runtime parity gate (Task #21) re-validates this from Xcode.
