# ADR 0003 — NAFNet Config Rescope (Phase B.1)

**Date**: 2026-05-26
**Status**: Accepted
**Branch**: `feature/forge-2026-q2-refresh`
**Supersedes spec in**: [Forge-CodingPlan-v1.0.md §B.1](../Forge-CodingPlan-v1.0.md)

---

## Context

Phase B.1 ported NAFNet's architecture from PyTorch ([megvii-research/NAFNet](https://github.com/megvii-research/NAFNet), MIT) to MLX-Swift at the plan's specified config: `width=32, encoderBlockNums=[2,2,2,2], middleBlockNum=1, decoderBlockNums=[2,2,2,2]`. The implementation is faithful to the upstream architecture (verified by shape, padding, and parameter-count tests passing) but parameter count came out at **~5.75M trainable parameters**.

The plan §B.1 wrote: *"width=32, blocks=8 (per re-eval — ~1.1 GMACs, ≤6 MB target)"*. That sentence conflates two different budgets:

- **~1.1 GMACs** is a compute budget for one 256×256 forward pass — independent of param count
- **≤6 MB** is a serialized-bundle target

At FP16, **5.75M params ≈ 11.5 MB on disk**, ~2× the 6 MB target. Replacing the v0.3 chain (DnCNN-color 1.1 MB + DnCNN-gray 1.1 MB + ARCNN 0.24 MB = ~2.4 MB) with an 11.5 MB NAFNet would push the ForgeOptimizer bundle from ~6 MB to ~15 MB, blowing past plan §4's `bundle_size_max` gate of **≤12 MB total**.

## Decision

Rescope NAFNet's *default* config to **`width=24, encoderBlockNums=[1,1,1,1], decoderBlockNums=[1,1,1,1], middleBlockNum=1`** (≈1.4M params, ≈2.8 MB FP16). This brings the ForgeOptimizer bundle to ~6 MB with NAFNet integrated — comfortably under the gate.

The wider `width=32 / [2,2,2,2]` config remains supported via explicit constructor args. If Phase B.3 training shows the smaller default underfits the joint denoise + artifact-removal task, the rescope reverses cleanly with no architectural change.

## Reasoning

The NAFNet paper's headline results (SIDD denoise + GoPro deblur) use much wider configs (`width=64`, longer block counts). The 2026 Q2 refresh re-eval picked NAFNet specifically because *a smaller config* still beats the v0.3 three-model chain on joint multi-degradation. We're not chasing absolute SOTA; we're consolidating three small task-specific models into one slightly-larger general-purpose one. A 1.4M-param model is still 3× the capacity of the legacy ARCNN (75K params) and 1.3× the legacy DnCNN-color (~550K params).

Bundle-size budget table after the rescope:

| Component | v0.3 size | After B.5 |
|---|---|---|
| DnCNN-color | 1.1 MB | (removed) |
| DnCNN-gray | 1.1 MB | (removed) |
| ARCNN | 0.24 MB | (removed) |
| **NAFNet (new)** | — | ~2.8 MB |
| ESPCN-x2 | 0.14 MB | 0.14 MB |
| ESPCN-x4 | 0.16 MB | 0.16 MB |
| QualityRegressor (Proprietary-Research) | 3.3 MB | 3.3 MB (Phase E replaces with SigLIP2-IQA) |
| **Total** | ~6.0 MB | ~6.4 MB |

The §4 gate has substantial headroom for Phase B if training shows the default underfits and a larger config is needed (up to ~5.5M params before breaching).

## Consequences

- `NAFNet()` default constructor changes signature semantics; existing call sites that relied on the architecture default get the rescoped one for free. No call sites today (only Phase B.5 will wire it).
- `NAFNetTests.parameterCount` band tightened from 0.8M–8M to 0.5M–3M; matches the new default.
- Phase B.3 training script (Task #12) targets the new default — total training compute drops roughly proportionally to params.
- Phase B.4 weight converter (Task #13) handles whatever config the trained checkpoint declares; the converter doesn't need to know about this decision.

## Revisit triggers

- Phase B.3 training acceptance fails (PSNR <35 dB on SIDD joint noise, or >0.3 dB worse than ARCNN on HEVC) → upsize. The architecture supports it; only the trained checkpoint differs.
- Phase E SigLIP2 replacement removes the 3.3 MB QualityRegressor → frees budget; we could afford the larger NAFNet config if it matters.
- Plan §4 `bundle_size_max` gate is raised (would require a separate ADR; the gate is a meaningful constraint for ergonomic app downloads).
