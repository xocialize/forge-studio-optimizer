# forge-studio-optimizer

The **non-realtime, quality-first** AI video stack for the **ForgeStudio**
umbrella (MVS Collective). Relocated from the `Forge` monorepo (2026-05-29) so
quality work can evolve independently of the realtime app.

Apple Silicon arm64 only. MLX-Swift + CoreML. No realtime requirement (ADR-0009).

## What's here

| Package | Role |
|---|---|
| `Packages/ForgeOptimizer` | AI analysis + preprocessing (NAFNet restoration, LiteFlowNet motion, SigLIP2 IQA, ModelRegistry) + the benchmark harness (`forge-benchmark-runner`, `forge-gate-checker`) |
| `Packages/ForgeUpscaler` | AI super-resolution — playback tier (SRVGGNetCompact-general, the C.4 winner) + export tier (Real-ESRGAN CoreML) |
| `Packages/FormatBridge` | Video decode (FFmpeg) + encode (VideoToolbox) engine |
| `Packages/FFmpegXC` | Vendored LGPL-safe FFmpeg static libs (`build.sh` rebuilds them) |
| `Packages/ForgeTraining` | Off-device Python training rig (NAFNet B.3 — restart-friendly; never shipped) |
| `Tests/Corpus` | 30-clip royalty-free benchmark corpus (manifest + fetch scripts; clips re-fetch) |
| `Docs` | ADRs (0001–0009), benchmark schema, PRDs, research, the C.4 report |

Dependency stack: `ForgeOptimizer → ForgeUpscaler → FormatBridge → FFmpegXC`, all
on `mlx-swift ≥ 0.31.2`. FormatBridge + FFmpegXC are a **self-contained copy** of
the shared Forge video engine (see "Provenance"); a shared `format-bridge` repo
is a future extraction.

## Build

```bash
# FFmpegXC static libs (first time, or on a fresh clone — they're gitignored)
cd Packages/FFmpegXC && ./build.sh

# Benchmark harness
cd Packages/ForgeOptimizer && swift build -c release --product forge-benchmark-runner

# Materialize the corpus (needs Homebrew ffmpeg-full for drawtext + libvmaf)
cd Tests/Corpus && ./scripts/fetch_corpus.sh
```

See `Packages/ForgeTraining/TRAINING.md` for the NAFNet training runbook.

## Provenance

Relocated from `xocialize-code/Forge` (`feature/forge-2026-q2-refresh`) on
2026-05-29 as a clean copy — full history lives in the Forge repo. The realtime
app (ForgeAlpha, MediaLibrary, the app shell) stays in Forge; this repo is the
quality/non-realtime home. `Docs/ForgeStudio-PRD-v0.1.md` is forward-looking
reference, not authoritative — the code is ahead of it.

Key decisions: ADR-0008 (SRVGGNet-general ships, EfRLFN rejected), ADR-0009
(realtime requirements dropped), ADR-0007 (Real-ESRGAN CoreML export).
