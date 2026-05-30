# ADR 0001 — Forge 2026 Q2 Refresh Kickoff Decisions

**Date**: 2026-05-26
**Status**: Accepted
**Branch**: `feature/forge-2026-q2-refresh`
**Owner**: Dustin / MVS Collective

---

## Context

`Docs/Forge-CodingPlan-v1.0.md` and `Docs/Forge-BenchmarkSchema-v1.0.md` landed in the working tree as the authoritative refresh of the Forge AI pipeline stack. Three open decisions surfaced before any Phase A work could begin:

1. **v0.3 baseline weights** — where they live and whether to recover or re-train them
2. **§1 directory layout** — whether to refactor the existing `Preprocessors/` tree to match the plan's `Restoration/` + `QualityRegressor/` + `ModelRegistry/` layout, or extend in place
3. **30-clip benchmark corpus** — whether clips exist or must be curated

This ADR captures the choices and the *reason for the choice*, so later phases don't re-litigate them.

---

## Decision 1 — Vendor v0.3 weights from `com.xocialize.coreml`

**Original answer** (2026-05-26 mid-day): re-train all baseline models on M5 Max in Phase 0.D, ~5 days unattended.

**Updated** (same day, after inspection): the canonical model repo [xocialize-code/com.xocialize.coreml](https://github.com/xocialize-code/com.xocialize.coreml) already contains `.mlpackage` builds of every v0.3 baseline (DnCNN-color, DnCNN-gray, ARCNN, ESPCN-x2, ESPCN-x4, QualityRegressor) for both macOS and iOS, plus PyTorch checkpoints under `training/checkpoints/` and training scripts mirrored in [video-combobulator](https://github.com/xocialize-code/video-combobulator/tree/HEAD/Training).

**Decision**: Phase 0.D vendors the macOS `.mlpackage` set from `com.xocialize.coreml` into `Packages/ForgeOptimizer/Resources/Models/` and verifies each loads under the new `ModelRegistry`. ~0.5 days. Re-training remains available as a fallback if any vendor verification fails.

**Bonus**: `realesrgan_x{2,4}.mlpackage` are also present. Phase D will evaluate them against the `themindstudio/RealESRGAN-x4plus-mlx` adoption path; not blocking the kickoff decision.

---

## Decision 2 — Refactor `Preprocessors/` to plan §1 layout

The current tree groups everything in `Packages/ForgeOptimizer/Sources/ForgeOptimizer/Preprocessors/` (`Denoiser.swift`, `ArtifactRemover.swift`, `SuperResolution.swift`, `QualityScorer.swift`, plus `CoreMLProcessor.swift` and `PreprocessorFactory.swift`). The plan §1 prescribes:

- `Restoration/` — DnCNN/ARCNN legacy paths and new NAFNet
- `QualityRegressor/` — legacy CNN and new SigLIP2 head
- `Analysis/Saliency/` — Apple Vision saliency wrapper
- `ModelRegistry/` — new model-loading actor

**Decision**: Refactor mechanically in Phase 0.B before Phase A or B begins. Move `Denoiser.swift` → `Restoration/Legacy/DnCNN.swift`, `ArtifactRemover.swift` → `Restoration/Legacy/ARCNN.swift`, `SuperResolution.swift` → `Restoration/Legacy/ESPCN.swift`, `QualityScorer.swift` → `QualityRegressor/Legacy/QualityScorer.swift`. Create empty new directories. Keep `CoreMLProcessor.swift` and `PreprocessorFactory.swift` at top level until ModelRegistry replaces them in A.3.

**Why over "extend in place"**: Phases B and E both produce new files under the same role (`Restoration/NAFNet.swift`, `QualityRegressor/SigLIP2_IQA.swift`). Putting them next to their legacy peers keeps reviewer cognitive load low. One mechanical commit now beats two confused trees later.

---

## Decision 3 — Curate 30-clip corpus from royalty-free sources

No existing corpus is checked into either Forge or `com.xocialize.coreml`. Plan §2.3 calls for 10 general / 10 signage / 10 legacy clips.

**Decision**: Curate in Phase 0.C. ~2 days.

- **General (10)**: Netflix Open Content (El Fuente, Meridian, Sol Levante), Blender Cloud (Sintel, Tears of Steel, Big Buck Bunny), public sports + screen-capture under CC-BY
- **Signage (10)**: Synthesize from public-domain logos + text overlays + transition templates; MVS Collective's own permission-cleared signage if available
- **Legacy (10)**: Internet Archive DVD/broadcast captures (MPEG-2, interlaced)

Hash with sha256, manifest matches the `CorpusClip` schema in `Docs/Forge-BenchmarkSchema-v1.0.md`. Lands at `Forge/Tests/Corpus/manifest.json`.

---

## Decision 4 — Hardware caveat for §4 gates

The benchmark plan §4 specifies M4 Pro (throughput, playback fps) and §2.4 specifies M5 Pro (training). Only an M5 Max 128 GB is locally available.

**Decision**: `BenchmarkSuite` emits all gates including `throughput_balanced_m4pro_1080p` and `playback_4k_fps_min`, marking them `hardware_required: "M4 Pro"`. CI's gate checker skips them when `hardware.chip != hardware_required`. M5 Max passes are necessary but not sufficient; real validation defers until M4 Pro hardware is procured.

---

## Consequences

- Phase 0 collapses from ~7 days to ~3-4 days (re-train was the long pole; vendoring is fast)
- Phase 0.B introduces a high-churn diff in one commit — reviewers should expect renames, not new logic
- The new directory layout becomes the contract every later phase enforces
- M4 Pro and M5 Pro gates remain reported but unevaluated until hardware lands; CI must not red over them

## Revisit triggers

- If `com.xocialize.coreml` vendor verification fails on any model → Phase 0.D falls back to re-training that model
- If C.4 (SPANV2 vs SRVGGNetCompact) shows the kernel-fusion advantage doesn't transfer to Metal → playback tier stays on SRVGGNetCompact and SPANV2 becomes future work (separate ADR)
- If a real corpus arrives later (licensed library, customer-provided) → §C revisits the 30-clip composition, hash manifest pins the version
