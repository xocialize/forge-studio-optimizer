# ADR 0010 — NAFNet B.3 Training Data: Domain Signage Frames

**Date**: 2026-05-29
**Status**: Accepted
**Relates to**: [ADR-0003](0003-nafnet-sizing-rescope.md) (NAFNet sizing), B.2 corpus generator (Task #11), B.3 training (Task #12)

---

## Context

NAFNet B.3 (the restoration model that replaces the v0.3 256²-resize Denoiser /
ArtifactRemover stubs) needs a high-quality (HQ) image source. The B.2 generator
crops 256² tiles from HQ frames and synthesizes degraded↔clean pairs (noise,
HEVC, AV1, MPEG-2). Two candidate HQ sources:

1. **DIV2K** — the general-purpose, diverse-texture restoration/SR standard
   (800 pristine PNGs). Generalizes well; the scientific baseline.
2. **IBM Think 26 signage masters** — the owner's own real signage content,
   already on disk: 3D brand animation, crowds/faces, sports textures,
   generative/abstract, typographic, and real 4K camera footage.

Forcing the issue: the canonical DIV2K mirror (ETH) downloaded at ~84 KB/s
(~11 hr for 3.3 GB), and the entry MVP target is **signage Vimeo-parity** — the
exact domain the IBM masters represent.

## Decision

**Use the IBM Think 26 signage frames as the B.3 HQ source.** Extract lossless
PNG frames from a curated, diversity-spanning set of ~23 masters (the cleanest
"Download from Blue Studios" copies where available), prune fade/near-black
frames, and feed them to the B.2 generator. Result: **1130 HQ frames** → 100k
degraded pairs → NAFNet train.

Rationale: domain-matched to the MVP target, on disk (no slow download), and a
restoration model trained on signage degradations is fit-for-purpose for a
signage product. DIV2K's broader generalization is not required for the entry
tier and can be added later (see revisit).

## Proprietary handling (binding)

The IBM Think 26 content is **third-party brand IP** (Ferrari, Wimbledon, UFC,
Grammys, US Open, Masters, Sevilla, IBM, etc.). Constraint: **local eval +
off-device training ONLY, never committed to the repo.**

- The **master manifest** (`data/ibm_hq_masters.txt`, which names the masters)
  lives under **gitignored `data/`** — it is never committed. The extractor
  (`Scripts/extract_hq_frames.sh`) is generic/content-agnostic and *does* ship.
- Extracted **HQ frames** and the **generated corpus** live under gitignored
  `data/` — never committed.
- Only the **trained NAFNet weights** ship. The weights learn a
  degradation→clean *restoration mapping*, not the content itself — they do not
  embed or reproduce the brand imagery. Shipping a restoration model trained on
  the owner's own signage is within rights and carries no third-party IP in the
  artifact.

## Consequences

- **Corpus-gen resilience hardening** (shipped alongside): at-scale generation
  (16 parallel workers, ~100k ffmpeg calls) surfaced transient single-pair codec
  failures that aborted the whole run — HEVC could not mux into ISOBMFF
  (mp4/mov) on this ffmpeg-full build, and MPEG-2 had a transient bad-output
  decode. Fixes: HEVC → Matroska container; **per-pair retry + pure-numpy noise
  fallback** in the worker; **`future.result()` wrapped** in the main loop so no
  single pair can kill a multi-hour run. The container was a symptom; the
  resilience is the cure.
- **Lower source diversity than DIV2K** (23 clips / 1130 frames vs 800 distinct
  photos), partly offset by domain match + per-frame temporal variety + heavy
  random-crop/degradation augmentation. Acceptable for the entry tier; a
  generalization gap to *non-signage* content is the known trade.
- B.3 → B.4 (PyTorch→MLX convert) → B.5 (wire, replaces v0.3 stubs) →
  unblocks the #40 compression-gate validation. Unchanged.

## Revisit triggers

- Cross-domain (non-signage) restoration quality matters → add DIV2K as a
  **mixed corpus** (`USE_DIV2K=1` downloads it; re-run generator `--resume` to
  blend), or fine-tune the signage model on DIV2K.
- A second domain's content becomes a target → extend the manifest (still
  local-only) and regenerate.

## References

- Pipeline: `Packages/ForgeTraining/Scripts/run_b3_pipeline.sh`
  (Stage 1 uses local HQ frames; DIV2K behind `USE_DIV2K=1`)
- Extractor: `Packages/ForgeTraining/Scripts/extract_hq_frames.sh`
- Generator: `Packages/ForgeTraining/Python/generate_multidegradation_corpus.py`
- [ADR-0003](0003-nafnet-sizing-rescope.md) — NAFNet width=24, 2.54M params
