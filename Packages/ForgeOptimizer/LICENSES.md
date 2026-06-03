# ForgeOptimizer — License Inventory

Tracks the SPDX licenses of every model, dataset, and code dependency that the ForgeOptimizer package depends on at runtime (in-app) or for training (off-device). All in-app models are gated by `ModelRegistry.LicensePolicy` at load time.

## Runtime models

### v0.3 baseline (vendored under `Sources/ForgeOptimizer/Resources/`)

See [`Sources/ForgeOptimizer/Resources/MODELS.md`](Sources/ForgeOptimizer/Resources/MODELS.md) for per-model SPDX, training data, and metrics. Summary:

| Model | SPDX | Status |
|---|---|---|
| `dncnn_color.mlpackage` | `Proprietary` | v0.3, replaced by NAFNet (Phase B.5) |
| `dncnn_gray.mlpackage` | `Proprietary` | v0.3, replaced by NAFNet (Phase B.5) |
| `arcnn.mlpackage` | `Proprietary` | v0.3, replaced by NAFNet (Phase B.5) |
| `espcn_x2.mlpackage` | `Proprietary` | kept; super-resolution side path |
| `espcn_x4.mlpackage` | `Proprietary` | kept; super-resolution side path |
| `quality_regressor.mlpackage` | `Proprietary-Research` ¹ | v0.3, replaced by SigLIP2-IQA (Phase E.5) |

¹ `quality_regressor` was trained on KADID-10k (non-commercial research-only). Refused by `LicensePolicy.commercial` at load time. Phase E.5 replaces it with the SigLIP2 NR-IQA head (Apache-2.0).

### Phase B (NAFNet, in flight)

| Model | SPDX | Status |
|---|---|---|
| `NAFNet` (architecture port) | `MIT` (upstream: `megvii-research/NAFNet`) | Implementation: [`Restoration/NAFNet.swift`](Sources/ForgeOptimizer/Restoration/NAFNet.swift). Weights: pending Phase B.3 training; trained weights are Forge / MVS Collective IP. |

### Phase E (SigLIP2 NR-IQA, in flight)

Per [ADR-0005](../../Docs/ADRs/0005-siglip2-lazy-download.md), the SigLIP2 backbone is **lazy-downloaded** at first use; **not** vendored in this package.

| Component | SPDX | Where |
|---|---|---|
| `google/siglip2-base-patch16-224` | `Apache-2.0` | upstream model card |
| `mlx-community/siglip2-base-patch16-224-8bit` | `Apache-2.0` (preserved) | quantized variant used at runtime — pinned to HF revision `5249fc157310584fe99dae6964707278eb6df50f` |
| NR-IQA head (2-layer MLP) | `MIT` (this repo) | Phase E.2 deliverable |

Apache-2.0 attribution (when shipping the in-app downloader / config):

```
Copyright © Google LLC
Licensed under the Apache License, Version 2.0;
https://www.apache.org/licenses/LICENSE-2.0
```

**SHA256 pins** (verified against HuggingFace on 2026-05-28; consumed by `SigLIP2BackboneLoader.manifest`):

| File | Size | SHA256 |
|---|---|---|
| `config.json` | 351 B | `b551f88347bd722299bd0d66fccf11a85a366adc58f0c09180765e3d38508e19` |
| `model.safetensors` | ~400 MB | `c2498ff9d590362c8c14becbcfa40fd172b105a8f4520c2e2a96905955651984` |

If upstream rotates either hash, the loader throws `SigLIP2BackboneLoader.LoaderError.checksumMismatch` rather than silently loading an unverified payload. Bump the manifest + this table together.

#### Phase E Plan-B — distillation insurance (post-research, 2026-05-26 PM)

External research ([Survey 1](../../Docs/Research/research-2026-05-26-three-surveys.md)) confirmed that **no permissive ≤10 MB NR-IQA exists** that hits SRCC ≥0.88 on KonIQ-10k. The realistic fallback for SigLIP2 isn't a swap — it's a retrain. Plan B if SigLIP2 lazy-download proves operationally untenable:

| Role | Source | License | Notes |
|---|---|---|---|
| Teacher | QualiCLIP+ (CLIP RN50 + prompt tuning) | `CC-BY-NC-4.0` | Teacher weights are non-commercial; trained-student weights are MVS Collective IP, **but** the "derived from CC-BY-NC teacher" status requires legal review before commercial release |
| Student | MobileNet-V3 + 2-layer MLP regressor (LAR-IQA-style) | `MIT` (architecture) | Trained from scratch on QualiCLIP+ pseudo-labels + KonIQ-10k MOS; target SRCC ≥0.85, ~5–10 MB FP16 |

Alternative tactical fallback if retraining isn't an option: **MUSIQ-single-scale** (`google-research/musiq`, Apache-2.0, ~27M params, ~54 MB FP16, SRCC 0.905 on KonIQ-10k). 8× smaller than SigLIP2 but 5–10× larger than the distilled student. Port from TF/Flax to MLX-Swift estimate: ~1 engineer-week.

**Status (#23, 2026-06-02) — explored, DECIDED research-only, NOT productized.** The
distillation pipeline was built + validated (a ~2 MB MobileNet-V3 student absorbed QualiCLIP+
at student↔teacher SRCC 0.920 on signage), but **SigLIP2 (Plan A) already delivers the
quality + functions we need**, so this Plan-B is **kept out of the product** to avoid the
CC-BY-NC exposure entirely. The work is preserved as a reference comparison on branch
`research/iqa-distillation-planb` (the experiment script + `Docs/Benchmarks/iqa-distillation-planb.md`
live there, NOT on `main`). Because nothing derived ships, **#30 legal review is moot** unless
reactivated. Revisit only if SigLIP2's lazy-download proves untenable in production.

### Phase B.6 watch-list

| Model | SPDX | Status |
|---|---|---|
| PocketDVDNet (arXiv:2601.16780) | TBD (research-only as of paper release; upstream code release pending) | Phase B.6 evaluates only if license clears |

## Optical flow (separate workstream)

| Model | SPDX | Status |
|---|---|---|
| LiteFlowNet (via `OpticalFlow/*.swift`) | `NTU CV` (TBD — see [SwiftLiteFlowNet PRDs](../../)) | Out-of-scope for the 2026 Q2 refresh per coding plan §0 |

## Off-device dependencies

### Training (`Packages/ForgeTraining/`)

The training rig (`requirements.txt`) pulls:

| Package | SPDX |
|---|---|
| `numpy` | `BSD-3-Clause` |
| `opencv-python` | `Apache-2.0` |
| `Pillow` | `MIT-CMU` |
| `ffmpeg-python` | `Apache-2.0` |
| `pytest` | `MIT` |
| `tqdm` | `MIT` (+ `MPL-2.0` for the progress-bar styling) |

PyTorch is a Phase B.3 / Phase E.4 training-only dependency (`BSD-3-Clause` + extension licenses). Not declared in `requirements.txt` to keep `setup.sh` minimal; training scripts will pull it explicitly.

### Training datasets

| Dataset | License | Used by |
|---|---|---|
| DIV2K | `CC-BY-4.0` | Phase B.2 / B.3 (NAFNet) — HQ source |
| Flickr2K | `CC-BY-NC-SA-4.0` ² | Phase B.2 / B.3 (NAFNet) — HQ source |
| KADID-10k | non-commercial research-only | v0.3 `quality_regressor` (legacy); Phase E.4 may re-use under research banner |
| KonIQ-10k | non-commercial research-only | Phase E.4 (SigLIP2-IQA head) — research banner |
| SPAQ | `CC-BY-4.0` | Phase E.4 — held out for evaluation |

² Flickr2K non-commercial restriction means trained NAFNet weights are derivative-work-questionable for commercial use. **Phase B.2's corpus generator must prefer DIV2K-only sourcing** for the commercial training run; Flickr2K is an internal augmentation only. Re-evaluate at Phase B.3 if quality acceptance fails with DIV2K-only.

## How LicensePolicy enforces this

`Packages/ForgeOptimizer/Sources/ForgeOptimizer/ModelRegistry/LicensePolicy.swift` provides:

- `.commercial` policy — refuses `Proprietary-Research` (and any future research-only SPDX tags)
- `.development` policy — allows everything; used by `BenchmarkSuite` and `forge-benchmark-runner`

At runtime, `ModelRegistry.load(_:)` calls `policy.check(_:)` before returning the loaded model. A commercial build that tries to load `quality_regressor.mlpackage` throws `ModelRegistryError.licenseRefused(.proprietaryResearch, .commercial)`.
