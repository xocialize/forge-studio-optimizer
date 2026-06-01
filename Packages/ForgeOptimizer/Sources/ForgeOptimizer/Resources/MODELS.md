# ForgeOptimizer Bundled Models — Provenance & License

These `.mlpackage` files are vendored from [xocialize-code/com.xocialize.coreml](https://github.com/xocialize-code/com.xocialize.coreml) at commit **`3989123`** (`models/macos/`). They are the v0.3 baseline pipeline; Phase B replaces several of them with NAFNet (joint denoise + artifact removal) and Phase E replaces `quality_regressor` with a SigLIP2 NR-IQA head.

| Model | Architecture | Task | Input → Output | Size | Training data | Training metric | SPDX |
|---|---|---|---|---|---|---|---|
| `dncnn_color.mlpackage` | DnCNN | RGB Gaussian-noise denoise | RGB 256×256 → RGB 256×256 | 1.1 MB | DIV2K + synthetic Gaussian noise | PSNR 30.07 dB | `Proprietary` ¹ |
| `dncnn_gray.mlpackage` | DnCNN | Luma denoise | Gray 256×256 → Gray 256×256 | 1.1 MB | DIV2K + synthetic Gaussian noise | PSNR 28.06 dB | `Proprietary` ¹ |
| `arcnn.mlpackage` | ARCNN | Compression artifact removal | RGB 256×256 → RGB 256×256 | 244 KB | DIV2K + HEVC artifacts | PSNR 29.06 dB | `Proprietary` ¹ |
| `espcn_x2.mlpackage` | ESPCN | 2× super-resolution | RGB 128×128 → RGB 256×256 | 140 KB | DIV2K bicubic-downsampled | — | `Proprietary` ¹ |
| `espcn_x4.mlpackage` | ESPCN | 4× super-resolution | RGB 64×64 → RGB 256×256 | 160 KB | DIV2K bicubic-downsampled | — | `Proprietary` ¹ |
| `quality_regressor.mlpackage` | MobileNetV3-small head | No-reference IQA | RGB 224×224 → scalar [0, 100] | 3.3 MB | **KADID-10k** ² | Pearson r 0.9032 | `Proprietary-Research` ² |

**Total**: ~6.0 MB

## Safetensors weights (MLX restoration + gate)

| Model | Architecture | Task | Size | Training data | Metric | SPDX |
|---|---|---|---|---|---|---|
| `nafnet.safetensors` | NAFNet (w24) | Joint denoise + artifact removal | 4.9 MB (fp16) | IBM signage frames + our codec degradations (ADR-0010) | val PSNR 41.5 dB | `Proprietary` (weights ship; frames don't) |
| `siglip2_iqa_head.safetensors` | 2-layer MLP on frozen SigLIP2 | No-reference IQA gate signal (Step 3) | 770 KB | **our** signage frames + our codec degradations, DISTS pseudo-MOS labels (ADR-0010/0016) | val SRCC 0.902 / PLCC 0.956 | `Apache-2.0` head over `Apache-2.0` backbone |

`siglip2_iqa_head` is the **realized Phase E replacement** for `quality_regressor` (the KADID-trained, non-commercial scorer flagged below ²). License-clean by construction — we degrade our own frames with our own codecs and label with a full-reference metric (DISTS), so no non-commercial IQA dataset is touched. It runs over the lazy-downloaded 8-bit SigLIP2 backbone (`mlx-community/siglip2-base-patch16-224-8bit`, Apache-2.0; dequantized on load, parity cosine 0.9999 vs FP — #57) and gates NAFNet default-on at threshold 0.78 (ADR-0016). Trainer/eval: `Packages/ForgeTraining/Scripts/{train,eval}_iqa_head.py`; data gen `Python/generate_iqa_dataset.py` (source frames stay off-repo / gitignored — only the head ships).

¹ Trained on DIV2K (CC-BY-4.0). Trained weights are MVS Collective IP; the SPDX `Proprietary` tag means the `LicensePolicy` actor needs an explicit allow-list to load them in commercial builds. Source training pipeline: [xocialize-code/video-combobulator/Training](https://github.com/xocialize-code/video-combobulator/tree/HEAD/Training).

² **License flag**: `quality_regressor` was trained on KADID-10k, which is licensed for *non-commercial research use only* (per the dataset's release terms). Trained-weight derivative status is legally murky. **This model is the explicit Phase E.5 replacement target** (SigLIP2 NR-IQA head, Apache-2.0). Until Phase E lands, treat the quality regressor as eval-only and gate it out of any commercial release with `LicensePolicy`. Captured as a Phase A.3 acceptance criterion (`ModelRegistry` refuses load on non-commercial license).

## Training reproducibility

PyTorch checkpoints at [com.xocialize.coreml/training/checkpoints/](https://github.com/xocialize-code/com.xocialize.coreml/tree/main/training/checkpoints):

- `arcnn/best_model.pth`
- `dncnn_color/best_model.pth`
- `dncnn_gray/best_model.pth`
- `quality_regressor/best_model.pth`

Per-model training scripts at [video-combobulator/Training/](https://github.com/xocialize-code/video-combobulator/tree/HEAD/Training):

- `train_arcnn.py`
- `train_dncnn_color.py`
- `train_dncnn_gray.py`
- `train_espcn.py`
- `train_quality_regressor.py`

To re-train any model on this machine: clone `video-combobulator`, run `Training/setup_training.sh`, then the corresponding `train_*.py`. M5 Max time per model is ~0.5–1.5 days per the original training logs.

## How they're loaded

The legacy loader is `ModelRegistry/Legacy/CoreMLProcessor.swift`. Once Phase A.3 lands, the `ModelRegistry` actor replaces it and enforces `weightLicense: SPDXLicense` at load time. Until then, model loading is via `Bundle.module.url(forResource: "<name>", withExtension: "mlpackage")` from the per-package resource bundle.

## Deployment target

macOS 15.0+. The `models/ios/` variants in `com.xocialize.coreml` are not vendored here; tvOS uses the macOS package (verified compatibility deferred to Phase 4).
