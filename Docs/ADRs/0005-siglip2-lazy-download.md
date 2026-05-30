# ADR 0005 — SigLIP2 Lazy-Download (Phase E.1)

**Date**: 2026-05-26
**Status**: Accepted
**Branch**: `feature/forge-2026-q2-refresh`
**Supersedes spec in**: [Forge-CodingPlan-v1.0.md §E.1](../Forge-CodingPlan-v1.0.md)

---

## Context

Phase E.1 calls for vendoring SigLIP2-base from `mlx-community` on Hugging Face to back the new NR-IQA QualityRegressor head. The plan §E.1 implies (and the §10 risk #4 confirms in passing) that the model should fit alongside the rest of the in-app `.mlpackage` bundle. The plan's hand-wave language was "SigLIP2-base ≤ ~80 MB."

The actual size is much larger:

| Variant | Format | Size on disk |
|---|---|---|
| `google/siglip2-base-patch16-224` | FP32 safetensors (400M params) | ~1.6 GB |
| Same at FP16 | safetensors | ~800 MB |
| `mlx-community/siglip2-base-patch16-224-8bit` | MLX int8-quantized | **~400 MB** |

The smallest pre-quantized MLX variant is **400 MB** — roughly **33× the original §E.1 budget** and **33× the §4 `bundle_size_max` gate of 12 MB**. Bundling it in `Forge.app` is not viable.

## Decision

**Ship SigLIP2 as a lazy-downloaded model.** The in-app `ForgeOptimizer` includes the head architecture (a 2-layer MLP) and a `SigLIP2BackboneLoader` actor that:

1. On first request, checks the local cache at `~/Library/Application Support/Forge/Models/SigLIP2/`
2. If absent, downloads `model.safetensors` + `config.json` + `tokenizer.json` from `huggingface.co/mlx-community/siglip2-base-patch16-224-8bit` at a pinned revision SHA
3. Verifies the safetensors checksum against a manifest pinned in the app binary
4. Stores under the cache path; subsequent loads are O(memcpy)
5. Loads into MLX; exposes `func encode(_ image: MLXArray) async throws -> MLXArray`

Forge.app stays well under 12 MB. Phase E's `quality_regressor_srcc_min` gate runs on dev machines (where the cache is warm after any Phase E.4 training run) and on user machines after the first model invocation.

## Reasoning

Apple App Store policy explicitly allows lazy-loading of ML models from the network at first use; many production apps (Pixelmator Pro, Topaz Photo AI, Affinity AI features) do exactly this for SigLIP-class backbones. Distilling SigLIP2 to a small student CNN was considered (option B of the E.1 question) and rejected because:

- ~3–5 extra engineering days
- Loses the perceptual-quality ceiling SigLIP2 brings (which is the whole point of swapping out the v0.3 bespoke CNN)
- Phase E.5 already targets a small MLP **head** atop the SigLIP2 backbone; the backbone *is* what gives the head its capacity

Drop-and-replace with a smaller pre-built model (option D) was also rejected — current MUSIQ / CLIP-IQA / Pieapp-style alternatives don't have the SOTA SRCC numbers (≥0.90 on KonIQ-10k) we're targeting.

Two-tier (option C) is a future enhancement after Phase E.5 lands and we see real numbers on a tiny CNN-only baseline. Not pursued at this gate.

## Pinned model

| Field | Value |
|---|---|
| Repo | `mlx-community/siglip2-base-patch16-224-8bit` |
| URL | https://huggingface.co/mlx-community/siglip2-base-patch16-224-8bit |
| Base model | `google/siglip2-base-patch16-224` (Apache-2.0) |
| License | Apache-2.0 (preserved by MLX quantization) |
| Size on disk | ~400 MB total (model.safetensors + tokenizer + config) |
| Input resolution | 224×224 RGB |
| Image-encoder embedding dim | 768 |
| Revision SHA | **(pin at Phase E.2 fetch time)** |

Revision SHA stays unpinned in this ADR because Phase E.1 does **not** vendor weights to git. Phase E.2 will fetch the model once, write the actual SHA into [`Packages/ForgeOptimizer/LICENSES.md`](../../Packages/ForgeOptimizer/LICENSES.md) and the in-app downloader manifest.

## Consequences

- `Packages/ForgeOptimizer/LICENSES.md` declares SigLIP2 Apache-2.0 attribution
- No `.mlpackage` or `.safetensors` lands in `Packages/ForgeOptimizer/Sources/ForgeOptimizer/Resources/` for SigLIP2 (the `.gitignore` whitelist isn't extended)
- Phase E.2 (NR-IQA head architecture) implements both the 2-layer MLP head AND the `SigLIP2BackboneLoader` actor that does the lazy fetch
- Phase E.5 integration in `BenchmarkSuite` becomes async (already is) — the harness can pre-warm the cache before timing the quality pass so download latency doesn't pollute speed metrics
- First-launch UX: Forge.app downloads ~400 MB the first time `QualityRegressor` is invoked. Surfaced as a progress indicator in the conversion UI (Marquee Studio Pro will gate this similarly)
- `quality_regressor_srcc_min` gate stays non-evaluable until Phase E.4 trains the head — same as before; the lazy-download decision doesn't change that

## Revisit triggers

- A SigLIP2 distillation ships that fits the bundle with ≥0.85 SRCC (we'd ship inline instead of lazy)
- Apple changes App Store policy on lazy ML downloads (very unlikely)
- A different backbone (e.g. SigLIP3, Florence) becomes available that's both smaller AND higher-quality

## References

- [Forge-CodingPlan-v1.0.md](../Forge-CodingPlan-v1.0.md) §E.1, §10 risk #4
- [Forge-Re-Evaluation-2026-05.md](../Forge-Re-Evaluation-2026-05.md) §2.2
- SigLIP2 paper: arXiv:2509.17374v2 (NR-IQA head ablation)
- HuggingFace: https://huggingface.co/mlx-community/siglip2-base-patch16-224-8bit
