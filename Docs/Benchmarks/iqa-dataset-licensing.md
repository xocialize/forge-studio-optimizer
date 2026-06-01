# NR-IQA training data — licensing review + decision (#56)

**Date**: 2026-06-01 · **Decision**: generate our own (pseudo-MOS), not a third-party
academic IQA dataset.

## Why (the licensing wall)
The gate needs a learned no-reference quality model (Step 3 / #51). The standard
academic NR-IQA datasets with human MOS are **not usable in a commercial App Store
product** — the same reason KADID was rejected (ADR precedent / `.permissiveOnly`):

| dataset | license finding | usable? |
|---|---|---|
| KADID-10k | non-commercial | ❌ (already rejected) |
| PaQ-2-PiQ / FLIVE (UT LIVE) | **CC-BY-NC-4.0** — commercial use prohibited | ❌ |
| KonIQ-10k | "freely available to the **research community**"; images from YFCC100M/Flickr (mixed CC, incl. NC) | ⚠️ research-only / risky |
| SPAQ | **no stated license** (open GitHub issue asking) | ⚠️ unusable for ship |
| UHD-IQA | CC0 Pixabay images — commercially usable | ✅ (good *generalization* augment; general-photo domain) |
| NITS-IQA | CC-BY, but ~400 imgs, synthetic distortions | ✅ but too small |

## Decision — generate our own (license-clean by construction)
Degrade our OWN clean source frames with OUR codecs and label each with a
**full-reference perceptual metric** vs the clean original (the "pseudo-MOS"
technique — a recognised approach). No third-party IQA dataset is touched.

- **Generator**: `Packages/ForgeTraining/Python/generate_iqa_dataset.py` — reuses the
  NAFNet `degradations.py` (noise/HEVC/AV1/MPEG-2) and labels with **DISTS** (`piq`,
  MIT) → quality ∈ [0,1]. Validated: clean = 1.00, degraded span 0.65–0.99 monotonic
  with severity; 4 unit tests green.
- **Domain match**: point `--clean-source` at the (proprietary, local) high-bitrate
  signage masters → frames stay off-repo, only the trained head ships (ADR-0010 handling).
- **Labeler is dev-only**: DISTS/VGG16 + ffmpeg are dev tools, never shipped — like
  ffmpeg-full for VMAF labeling. Only the SigLIP2 head trained on the labels ships.
- **UHD-IQA (CC0)** is the optional generalization augment, and the better seed for
  ImageBridge's general still-quality metric later.

## Training pipeline (built + smoke-validated)
Both Python pieces exist and are tested; the **frozen** SigLIP2 backbone (Apache-2.0,
8-bit, already shipped) is reused — we only fit + ship the tiny ~200k-param head.

```
# 1. Generate labeled tiles from the LOCAL signage masters (proprietary, off-repo).
python Python/generate_iqa_dataset.py \
    --clean-source <signage-masters-dir> --out data/iqa_ds \
    --tile-size 224 --variants 8 --metric dists
# 2. Extract embeddings (frozen SigLIP2) → fit head → emit MLX-format safetensors.
python Scripts/train_iqa_head.py --dataset data/iqa_ds --out data/iqa_head
#    → data/iqa_head/siglip2_iqa_head.safetensors  (fc1/fc2 weight+bias) + metrics.json
```
Smoke run (6 master frames → 54 tiles) produced the correct head shape and a learned
mapping; a real run needs more sources + GPU time for meaningful SRCC/PLCC.

## Remaining for #56
1. Real data-gen run on the signage masters + train (above) → a head with strong val
   SRCC/PLCC.
2. Vendor `siglip2_iqa_head.safetensors` into ForgeOptimizer Resources; load it in a
   **SigLIP2-backed `NoReferenceQualityScoring`** (backbone + head + mean-pool).
3. **Re-validate the gate** (`forge-quality-target --score`) on real clean AND degraded
   (incl. Snowflake 045) — confirm it separates them AND the FP-train / 8-bit-infer
   embedding gap is benign. THEN default-on `PreprocessorFactory.makeGatedChain`.

## Sources
- [PaQ-2-PiQ (CC-BY-NC)](https://github.com/utlive/PaQ-2-PiQ) ·
  [KonIQ-10k](https://database.mmsp-kn.de/koniq-10k-database.html) ·
  [SPAQ](https://github.com/h4nwei/SPAQ) ·
  [UHD-IQA](https://arxiv.org/pdf/2406.17472) · pseudo-MOS technique (full-reference proxy labels)
