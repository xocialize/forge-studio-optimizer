# Benchmark Framework

Phase A.2 deliverable from [Docs/Forge-CodingPlan-v1.0.md](../../../../../Docs/Forge-CodingPlan-v1.0.md). On-disk schema is authoritative in [Docs/Forge-BenchmarkSchema-v1.0.md](../../../../../Docs/Forge-BenchmarkSchema-v1.0.md).

## Files

- **`BenchmarkReport.swift`** — top-level Codable shape (`BenchmarkReport`) plus `GitInfo`, `HardwareInfo`, and `Dependencies`. Drop-in from schema §4. All types `Sendable`.
- **`BenchmarkCorpus.swift`** — `Corpus` + `CorpusClip`. `CorpusClip` declares only the schema-required fields; extra fields in `manifest.json` (`source_url`, `license`, `attribution`, `fetch_notes`) are ignored on decode by Swift's `Decodable`.
- **`PipelineResults.swift`** — the `pipeline_results` payload: `ForgeOptimizerResults`, `ForgeUpscalerResults` with its three `tiers` slots, and `ModelInventoryEntry` (which shares role raw values with `ModelRegistry.ModelRole` by design).
- **`BenchmarkRuns.swift`** — per-clip `OptimizerRun` and `UpscalerRun` records plus the shared `RunStatus` enum (`success | partial | failed`).
- **`BenchmarkMetrics.swift`** — `SpeedMetrics` (distribution, not scalar — see schema §1), `QualityMetrics`, `MemoryMetrics`, `CompressionMetrics`, `TextMetrics`.
- **`GateEvaluation.swift`** — the `gates` payload (`GateEvaluation` + `GateResult`).
- **`AnyCodable.swift`** — type-erased helper for the free-form `encoder_settings` field in `CompressionMetrics`. `@unchecked Sendable` because it boxes `Any`.

- **`HardwareProbe.swift`** — captures `HardwareInfo` via `sysctlbyname` + `ProcessInfo.thermalState` + `IOPSCopyPowerSourcesInfo`. The chip parser maps `machdep.cpu.brand_string` (`"Apple M5 Max"`) to the schema-friendly form (`"M5 Max"`).
- **`GitProbe.swift`** — captures `GitInfo` by shelling out to `git rev-parse HEAD`, `git rev-parse --abbrev-ref HEAD`, `git status --porcelain`, and `git config --get remote.origin.url`. Returns nil for non-git directories.
- **`DependencyProbe.swift`** — captures `Dependencies`. Parses `Package.resolved` for the `mlx-swift` pin; subprocesses `swift --version`, `xcodebuild -version`, and the ffmpeg-full binary at `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg` (per ADR 0002, dev-toolchain not runtime).

- **`CorpusLoader.swift`** — reads `Forge/Tests/Corpus/manifest.json` into a `Corpus`. Pre-normalizes `null` values for `duration_s` and `sha256` so the strict schema types still bind before `fetch_corpus.sh` runs.
- **`InventoryEnumerator.swift`** — translates the registry's `[ModelManifest]` into the report's `[ModelInventoryEntry]`. `bundle_bytes` is the sum of `size_bytes`; `.mlpackage` directories are walked recursively.

- **`QualityMeasure.swift`** — PSNR / SSIM (pure Swift on luma plane of `CVPixelBuffer`), VMAF (subprocess to ffmpeg-full's `libvmaf`), LPIPS (stub returning 0; real implementation is Phase B).
- **`GateEvaluator.swift`** — the 7-gate catalog from schema §5 / coding-plan §4 and a pure-function `evaluate(report:)`. Skips `hardware_required` gates when `report.hardware.chip` doesn't match (per ADR 0001 §Decision 4); skipped gates emit `actual: 0, passed: false` with a `[SKIPPED: ...]` description so CI's regression diff stays stable.
- **`BenchmarkSuite.swift`** — actor that orchestrates one run: holds the corpus + registry + an optional `BenchmarkRunner`, accepts per-clip runs (real runtime when a runner is wired; `.failed` placeholder when nil for unit tests), probes host/git/deps, evaluates gates, emits one `BenchmarkReport`. `write(report:toFile:)` uses pretty-printed JSON with sorted keys + ISO-8601 dates.
- **`BenchmarkRunner.swift`** — the real runtime path. Decodes one clip via `FormatBridge`'s `FFmpegDecoder`, pushes each `CVPixelBuffer` through `PreprocessorFactory.makeChain(for:)` (same code path the Forge app uses), encodes the result via a direct video-only `AVAssetWriter`, and captures per-frame `ContinuousClock` timing, `mach_task_basic_info` peak resident bytes, sampled PSNR/SSIM, and a one-shot `libvmaf` subprocess. `runUpscalerPass(tier:clip:)` is wired but currently returns `.failed` with `failureReason: "ForgeUpscaler weights not yet vendored (SRVGGNet/RRDBNet); Phase C/D scope"` until the upscaler tier weights land.

## CLI executables

Two `.executableTarget`s are declared in `Package.swift`:

### `forge-benchmark-runner`

Drives the suite against every clip × every `OptimizationLevel` + every upscaler tier and emits one JSON report:

```bash
xcrun swift run forge-benchmark-runner \
  --corpus Forge/Tests/Corpus/manifest.json \
  --output Docs/Benchmarks/benchmark-baseline-v0.3-mlx-0.31.3-$(git rev-parse --short HEAD).json \
  --run-label "baseline-v0.3-mlx-0.31.3" \
  --notes "Capture after MLX bump"
```

Optional flags:
- `--skip-vmaf` — disable the VMAF subprocess
- `--levels off,light,balanced,aggressive,maximum` — subset of levels
- `--clip-ids id1,id2,...` — subset of clips
- `--tiers playback,export,signage` — subset of upscaler tiers

Exit codes: `0` = clean run, `1` = report written but at least one run was `.partial` or `.failed` (filename rewritten as `benchmark-PARTIAL-…`), `2` = system error. The CLI walks the optimizer runs after the sweep to derive `ratio_vs_baseline` / `savings_vs_baseline` for non-`.off` levels against the matching `.off` run; gates are re-evaluated against the derived compression metrics.

### `forge-gate-checker`

Diffs the gate results in a current report against a baseline report:

```bash
xcrun swift run forge-gate-checker \
  --report Docs/Benchmarks/benchmark-current-…json \
  --baseline Docs/Benchmarks/benchmark-baseline-v0.3-mlx-0.31.3-…json \
  --fail-on regression       # default
```

Exit codes: `0` = no regressions, `1` = at least one gate transitioned `passed:true → passed:false`, `2` = system error. Per schema §6, newly failing gates with no baseline entry are *warnings*, not failures — this keeps one-off blocked gates (like `quality_regressor_srcc_min` pre-Phase-E) from breaking the pipeline.

## Phase C/D follow-ups

- **ForgeUpscaler weights.** `runUpscalerPass` returns `.failed` until SRVGGNet (playback tier) and RRDBNet (export tier) `.mlpackage` files are vendored under `Packages/ForgeUpscaler/Resources/`. The decode + encode glue is in place; only the model load fails.
- **Legacy chain output size.** The v0.3 `Denoiser` / `ArtifactRemover` return 256×256 buffers via tiled CoreML inference. The encoder is configured for the source resolution, so the output mp4 is currently letterboxed / cropped. Phase B replaces these with the NAFNet / SPANV2 chain that processes at native resolution; the runner needs no changes when that lands.
- **VMAF on size-mismatched outputs.** Until the chain returns native-resolution buffers, VMAF compares 256×256 output against the native reference; the subprocess returns `0.0` for processed levels. PSNR / SSIM are computed on the unprocessed-input vs in-flight buffer pair, so they remain meaningful.
- **LPIPS.** Stub returning `nil`. A real LPIPS implementation needs AlexNet or VGG on every frame pair; deferred to Phase B.

## Schema round-trip

The `BenchmarkTests` test suite exercises the §3 canonical example: decode → re-encode → re-decode preserves every field, gate ID, and run record. That's the sanity check that the §4 Swift types haven't drifted from the JSON schema.
