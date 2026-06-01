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

## Remaining for #56
Training script (fine-tune the ported SigLIP2 NR-IQA head on the labeled tiles —
needs `transformers` + the SigLIP2 backbone weights) → convert to MLX → wire into
`NoReferenceQualityScoring` → re-validate the gate (`forge-quality-target --score`)
on real clean AND degraded (incl. Snowflake 045) → default-on the gated chain.

## Sources
- [PaQ-2-PiQ (CC-BY-NC)](https://github.com/utlive/PaQ-2-PiQ) ·
  [KonIQ-10k](https://database.mmsp-kn.de/koniq-10k-database.html) ·
  [SPAQ](https://github.com/h4nwei/SPAQ) ·
  [UHD-IQA](https://arxiv.org/pdf/2406.17472) · pseudo-MOS technique (full-reference proxy labels)
