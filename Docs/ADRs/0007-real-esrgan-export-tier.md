# ADR 0007 — Real-ESRGAN Export Tier Backend Selection

**Date**: 2026-05-27
**Status**: Accepted
**Branch**: `feature/forge-2026-q2-refresh`
**Implements**: [Forge-CodingPlan-v1.0.md §D.1](../Forge-CodingPlan-v1.0.md), [ForgeUpscaler-PRD-v0.1.md §4.3](../../ForgeUpscaler-PRD-v0.1.md)
**Predecessors**: [ADR-0001 §1](0001-forge-2026-q2-refresh-kickoff.md) (the "Phase D backup data point")

---

## Context

Phase D wires Real-ESRGAN behind a new `ExportTier` protocol in ForgeUpscaler. The plan §D.1 named [`themindstudio/RealESRGAN-x4plus-mlx`](https://huggingface.co/themindstudio/RealESRGAN-x4plus-mlx) as the primary backend; ADR-0001 §1 noted a backup data point — the [`xocialize-code/com.xocialize.coreml@3989123`](https://github.com/xocialize-code/com.xocialize.coreml) `realesrgan_x{2,4}.mlpackage` set was vendored in Phase 0.D and sits under `Packages/ForgeUpscaler/Sources/ForgeUpscaler/Resources/`.

Phase D's brief required evaluating both candidates against three failure conditions before defaulting to the plan's primary:

1. The MLX port's BSD-3-Clause status unclear / non-permissive
2. The MLX port stale / broken
3. Loading from Hugging Face impractical (no downloadable safetensors, oversized weights)

## Inspection findings (2026-05-27)

### Candidate A — `themindstudio/RealESRGAN-x4plus-mlx`

Retrieved via `huggingface.co/themindstudio/RealESRGAN-x4plus-mlx/tree/main` and `.../raw/main/README.md`:

| Property | Value |
|---|---|
| License (HF metadata) | `bsd-3-clause` |
| `LICENSE` file in repo | **Absent**. README defers to upstream `xinntao/Real-ESRGAN` |
| Weights format | **`.npz`** (MLX Python pickle), not `.safetensors` |
| Weight file size | 67 MB |
| Swift loader example | **None.** README's only usage example is `huggingface-cli download` |
| `config.json` / tokenizer | None |
| Repo activity | Last commit ~5 months ago, single contributor |
| Architecture detail | One paragraph in the 666-byte README, no diagram |

### Candidate B — vendored `realesrgan_x{2,4}.mlpackage`

| Property | Value |
|---|---|
| License | BSD-3-Clause (Real-ESRGAN upstream; CoreML conversion preserves) |
| Pin | `xocialize-code/com.xocialize.coreml@3989123`, `models/macos/` |
| Total size on disk | ~3.6 MB (x2 = 1.2 MB, x4 = 2.4 MB; FP16 quantised) |
| Input shape | Fixed `[1, 3, 128, 128]` |
| Output shape | `[1, 3, 256, 256]` (x2) / `[1, 3, 512, 512]` (x4) |
| Swift integration | Trivial — `MLModel.compileModel(at:)` + existing `TileProcessor` |
| Activity | Vendored 2026-05-26; upstream Real-ESRGAN BSD-3 stable since 2022 |

## Decision

**Adopt Candidate B (the vendored CoreML mlpackages) as the Phase D export-tier backend.** Wire it as `ForgeUpscaler.RealESRGAN_CoreML` behind the new `ExportTier` protocol.

The plan §D.1 default explicitly said *"Wrap the port behind `ForgeUpscaler.ExportTier` protocol"* — but **the port doesn't exist in a form that can be wrapped from Swift**. The Hugging Face repo ships a Python `.npz` pickle with no Swift loader, no safetensors equivalent, and no `config.json` / architecture serialisation. Adopting it would mean (a) writing an `.npz` reader, (b) porting RRDBNet to MLX-Swift from scratch, and (c) building the loader — a from-scratch MLX-Swift implementation, not the "wrap a port" the plan envisioned. That work is roughly equivalent to the in-house RRDBNet port the §2.4 re-eval finding explicitly said *"no longer pays for itself"*.

This triggers the brief's failure condition #3 (*"Loading from HuggingFace is impractical (e.g. the safetensors aren't downloadable...)"*). Candidate B is the right pick.

## Trade-offs

What we lose by not picking Candidate A:

- **MLX-Swift surface uniformity.** The 2026 refresh's other backbones (NAFNet, EfRLFN, SigLIP2) are all MLX-Swift. Real-ESRGAN now sits in CoreML, mixed with the legacy CoreML restoration models. Mitigation: `ExportTier` is the abstraction layer — a future MLX-native `RealESRGAN_MLX` swap-in is one new conformer away.
- **Apple Silicon GPU+ANE flexibility.** The MLX path would pick its own compute lanes. The CoreML path uses `MLComputeUnits.all`, which is good but Apple-controlled.
- **Training extensibility.** MLX weights are fine-tunable in `ForgeTraining`. CoreML weights are inference-only. Phase F (signage fine-tune) would need to re-train upstream and re-convert — captured below as a revisit trigger.

What we lose by not picking Candidate B (hypothetical, included for completeness):

- Nothing — the vendored mlpackages were always going to ship as a fallback per ADR-0001.

## Tile-shape deviation from plan §D.2

Plan §D.2 specifies **256×256 tile input, 32 px overlap**. The vendored CoreML mlpackage has a *fixed* `[1, 3, 128, 128]` input — feeding a 256-px tile would fail at `MLModel.prediction` time. `RealESRGAN_CoreML` therefore reports `inputTileSize = 128, tileOverlap = 16`, matching the shape `PlaybackUpscaler` uses for the SRVGGNet path.

Practical effect on the 30-clip benchmark corpus:

- 1080p input at 4× scale: `(1920/112) × (1080/112) ≈ 18 × 10 ≈ 180` effective tiles
- Output 7680×4320, ~3-10 s/frame on M5 Max (per §D.1 latency budget)
- Seam quality: linear-blend feather over 16-px overlap. The corresponding 32-px overlap on a 256 tile would give a 1:8 overlap ratio (12.5%); 16-px on a 128 tile gives the same 1:8 ratio. Quality should be equivalent at the seam.

If the eventual MLX-native swap-in adopts flexible input shape, it can move to 256/32 by overriding `inputTileSize` / `tileOverlap` on its `ExportTier` conformer. The plan-spec shape lives in the protocol's documented "typical" value.

## Consequences

- `Packages/ForgeUpscaler/Sources/ForgeUpscaler/Export/ExportTier.swift` — new protocol surface
- `…/Export/RealESRGAN_CoreML.swift` — concrete tier, ~135 LOC
- `…/Export/OSEDiff_MLX.swift` — Phase D.3 stub
- `…/Export/ExportUpscaler.swift` — refactored to wrap an `ExportTier`; legacy constructors preserved
- `ExportPipeline.swift` is untouched, per the Phase D scope rule
- `LICENSES.md` extended with the Phase D adopted-backend section
- `Resources/MODELS.md` updated: the mlpackages flip from "backup data point" to "in use, Phase D"
- `BenchmarkSuite` now has a stable `tier.name = "real-esrgan-coreml"` to label results under
- Future Phase F signage fine-tune cannot use this binary directly — it needs PyTorch upstream weights → fine-tune → re-convert to CoreML. Documented in revisit triggers.

## Acceptance status (deferred items)

- Phase D.1 acceptance — *"Output matches PyTorch reference within LPIPS 0.01"* — is **deferred**. `Packages/ForgeOptimizer/Sources/ForgeOptimizer/Benchmark/QualityMeasure.swift` LPIPS is a stub returning 0 (per `Packages/ForgeUpscaler/Tests/ForgeUpscalerTests/ExportTierTests.swift` TODO). When LPIPS lands (Phase E follow-up), add the parity check.
- Phase D.2 acceptance — *"Seamless output on the 30-clip corpus"* — deferred until BenchmarkRunner produces real quality scores.
- Phase D.3 acceptance — *"Protocol compiles; runtime throws notYetImplemented"* — **passing.** See `OSEDiff_MLX` smoke tests.

## Revisit triggers

- **MLX adoption proves problematic across other phases** (e.g. mlx-swift 0.31.2 breaks NAFNet / EfRLFN paths and we end up rolling back) → CoreML stays as the export tier permanently; document a new ADR closing the MLX-Swift export option.
- **`themindstudio/RealESRGAN-x4plus-mlx` ships a Swift loader, safetensors weights, or a `config.json`** → re-evaluate. The `ExportTier` abstraction makes the swap mechanical.
- **A new MLX-Swift Real-ESRGAN port lands from a more active maintainer** (e.g. mlx-community/realesrgan-x4plus) with weights ≤100 MB and a Swift example → re-evaluate per the ADR-0005 lazy-download pattern.
- **Phase F signage fine-tune needs to start** → either keep CoreML inference + retrain upstream Python, or pivot to the MLX-Swift path purely for training extensibility. Decision deferred to Phase F.
- **OSEDiff DiffusionKit SD 2.1 path matures** (calendar trigger: 2026-Q3 check) → flip `OSEDiff_MLX` from stub to real, A/B against `RealESRGAN_CoreML`. Per re-eval §2.6.

## References

- [Forge-CodingPlan-v1.0.md §D](../Forge-CodingPlan-v1.0.md)
- [Forge-Re-Evaluation-2026-05.md §2.4](../Forge-Re-Evaluation-2026-05.md)
- [ForgeUpscaler-PRD-v0.1.md §4.3](../../ForgeUpscaler-PRD-v0.1.md)
- [ADR-0001 §1 — Phase D backup data point](0001-forge-2026-q2-refresh-kickoff.md)
- [ADR-0005 — SigLIP2 lazy-download (pattern reference for future MLX swap)](0005-siglip2-lazy-download.md)
- [Packages/ForgeUpscaler/LICENSES.md — Phase D section](../../Packages/ForgeUpscaler/LICENSES.md)
- [Packages/ForgeUpscaler/Sources/ForgeUpscaler/Resources/MODELS.md](../../Packages/ForgeUpscaler/Sources/ForgeUpscaler/Resources/MODELS.md)
- Upstream Real-ESRGAN: [`xinntao/Real-ESRGAN`](https://github.com/xinntao/Real-ESRGAN), BSD-3-Clause
- CoreML conversion source: [`xocialize-code/com.xocialize.coreml@3989123`](https://github.com/xocialize-code/com.xocialize.coreml/tree/3989123)
- Rejected MLX port: [`themindstudio/RealESRGAN-x4plus-mlx`](https://huggingface.co/themindstudio/RealESRGAN-x4plus-mlx)
