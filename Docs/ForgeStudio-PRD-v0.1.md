# ForgeStudio PRD v0.1

**Status:** Draft for review
**Owner:** Dustin / MVS Collective
**Created:** 2026-05-26
**Sibling to:** Forge PRD v0.3 (realtime track)
**Distribution:** SPM package; thin boundary; consumer-agnostic API
**Consumers (initial):** Signage client-file CLI (internal), MVS media player (planned), Forge.app (future)

---

## 1. Purpose

ForgeStudio is the quality-maximizing track of the Forge ecosystem. Where Forge optimizes for realtime constraints (≥30 fps playback, bounded latency, on-device preview), ForgeStudio optimizes for *output quality at any reasonable cost in time and memory*. The two tracks share file formats, color management conventions, and the broader Forge brand, but they make different architectural trades.

ForgeStudio exists because the realtime track cannot deliver acceptable results on three classes of work that MVS Collective regularly encounters:

1. **Client-delivered signage files that are broken on arrival** — wrong codec, wrong resolution, baked-in compression artifacts, MPEG-2 era encoding rescued from DVDs, mismatched aspect ratios. Today this gets handled manually with FFmpeg incantations and Adobe Media Encoder. ForgeStudio replaces that with a deterministic batch pipeline.
2. **Library upscale and enhancement** for the eventual MVS media player. Users want "make this old video look as good as it possibly can on my hardware" with no time budget — overnight is fine if the result is meaningfully better.
3. **Archival re-mastering** — preserving content at higher quality for future use, where a 10x time investment over realtime is acceptable for noticeably better output.

## 2. Non-goals

ForgeStudio is explicitly not:

- A realtime playback tier. Forge's `ForgeUpscaler.playback` exists for that.
- A streaming or live-content tool. No live ingest, no per-frame latency budget.
- A UI product. ForgeStudio surfaces API; consumers provide UI.
- A codec replacement. ForgeStudio uses standard codecs (H.264, HEVC, AV1 via VideoToolbox) for output; the quality gain comes from pre/post-encode neural processing, not from neural bitstreams.
- A general-purpose ML framework. ForgeStudio embeds specific models for specific tasks. Consumers who want raw model access should reach for MLX directly.

## 3. Architecture and SPM boundary

### 3.1 Thin boundary

ForgeStudio exposes a task-oriented Swift API. The consumer (signage CLI, media player, Forge.app) owns:

- All UI surfaces — progress, settings, file pickers, presets
- File system orchestration — input/output paths, naming conventions, backup policies
- Batch queue management — what runs when, retry logic, scheduling
- User-facing telemetry and analytics
- Cancel and pause semantics from the user's perspective

ForgeStudio owns:

- Hardware probing and tier policy
- Model loading, weight caching, and download management
- Pipeline composition for each task verb
- Inference execution and progress callback emission
- Per-task acceptance reporting (quality metrics, runtime, memory peak)
- Failure modes (out-of-memory, missing model, license violation)

### 3.2 Package layout

```
ForgeStudio.xcworkspace/   # Standalone workspace; can also be consumed via SPM
└── Packages/
    └── ForgeStudio/
        ├── Package.swift
        ├── Sources/
        │   ├── ForgeStudio/                 # Public API
        │   │   ├── ForgeStudio.swift        # Top-level entry
        │   │   ├── Tasks/                   # enhance, upscale, restore, batch
        │   │   ├── Tier/                    # Tier enum + capability detection
        │   │   ├── Models/                  # Model identity, provenance, manifests
        │   │   └── Errors/
        │   ├── ForgeStudioCore/             # Internal — pipeline execution
        │   │   ├── ModelRegistry/
        │   │   ├── WeightCache/             # Lazy download, integrity, eviction
        │   │   ├── HardwareProbe/
        │   │   ├── Pipeline/                # Pipeline composition
        │   │   └── Telemetry/               # Internal metrics (not user analytics)
        │   └── ForgeStudioModels/           # Embedded small CoreML models live here
        ├── Resources/
        │   └── EmbeddedModels/              # CoreML .mlpackage for compact models
        └── Tests/
```

Three Swift modules, public surface limited to `ForgeStudio`.

### 3.3 Dependency policy

- Depends on MLX-Swift ≥0.31.2 (matches Forge baseline)
- Depends on xocialize-code packages where they exist (`nafnet-mlx` from Effort B, `efrlfn-mlx` from Effort A, future SeedVR2 bindings)
- No Foundation-only fallbacks; ForgeStudio is Apple Silicon arm64 only by design
- No Python at runtime; no Python in CI
- Build tool is `xcodebuild`; `Package.swift` is a dependency manifest

## 4. Hardware tier policy

### 4.1 Runtime probe

ForgeStudio probes hardware at first use via a single static call:

```swift
let capabilities = ForgeStudio.HardwareCapabilities.probe()
// capabilities.unifiedMemoryGB: Double
// capabilities.gpuCoreCount: Int
// capabilities.chip: ChipFamily
// capabilities.thermalState: ProcessInfo.ThermalState
// capabilities.ceilingTier: Tier
```

The probe runs once per process, caches its result, and re-evaluates thermal state on demand (not the full probe — just the thermal component) when the consumer asks. Memory is read via `host_statistics64` / `task_vm_info`; GPU core count via `IORegistry`; chip family via `sysctl hw.model` mapping.

### 4.2 Tier enum

```swift
public enum Tier: Comparable, Sendable {
    case base       // 16-24 GB unified memory, M-series base or Pro entry
    case enhanced   // 32-48 GB, M-series Pro / mid Max
    case premium    // 64-96 GB, M-series Max / high-end
    case ultra      // 128 GB+, M-series Max with max RAM, or M-series Ultra
}
```

Tier ceiling is determined by the strictest of three signals: available unified memory (after a safety reserve), GPU core count (a four-core GPU at 64 GB shouldn't run `ultra` workloads even if RAM allows), and thermal state at probe time. Thermal state below `nominal` lowers the ceiling by one tier; below `serious` lowers by two.

### 4.3 Tier-to-model mapping

The mapping is internal to ForgeStudio. Consumers never name models; they name tiers and tasks.

| Tier | Restoration backbone | Upscaler (export-grade) | Quality oracle | Notes |
|---|---|---|---|---|
| `base` | NAFNet width-32 8-block (embedded CoreML) | Real-ESRGAN MLX (~17 MB MLX port) | SigLIP2-base lazy-download (~400 MB) | Embedded path for offline-first |
| `enhanced` | NAFNet width-64 (lazy) | SeedVR2-3B (lazy, ~6 GB) | SigLIP2-base | One-step diffusion SR enters here |
| `premium` | NAFNet width-64 + ARCNN-class refinement pass | SeedVR2-7B (lazy, ~14 GB) | MoonViT-SO-400M as oracle (if license permits at integration time) | Two-pass restoration becomes viable |
| `ultra` | Multi-model ensemble + cross-validation | SeedVR2-7B at higher tile counts; longer inference; possible OSEDiff once licensed | MoonViT or larger | "No compromise" tier |

This table is intentionally placed inside the PRD so it can be revised without API breakage. The public surface only exposes `Tier`, not model names.

### 4.4 Tier override

Consumers can request a specific tier explicitly. If the requested tier exceeds the runtime ceiling, ForgeStudio fails fast with a `tierUnavailable` error including the actual ceiling and the gap (e.g. "requested premium, ceiling is enhanced; need 24 GB more unified memory or a non-base GPU"). The consumer decides how to surface that.

Consumers can also request `tier: .auto` (default), which uses the ceiling minus a configurable safety margin (default: one tier below ceiling, so a `premium`-capable machine defaults to `enhanced` to leave headroom for other apps).

## 5. Model bundling and weight management

### 5.1 Embedded vs downloaded

Models smaller than ~50 MB at the FP16 path stay embedded in the `ForgeStudioModels` resource bundle as CoreML `.mlpackage`. This covers:

- NAFNet width-32 8-block (~6 MB, the `base` tier restoration backbone)
- Any future small classical-style ROI/saliency models if they prove valuable
- A small quality regressor distilled from SigLIP2 (the Survey 1 Plan B candidate; ships if the distillation work in xocialize-code Q4 completes)

Everything else is **lazy-downloaded** on first use of a tier that needs it. This includes:

- SigLIP2-base (~400 MB)
- SeedVR2-3B and SeedVR2-7B (multi-GB each)
- Larger NAFNet variants
- MoonViT-SO-400M (~800 MB FP16)
- Any future diffusion-class model

### 5.2 Weight cache

```swift
public actor ForgeStudio.WeightCache {
    public func isPresent(_ model: ModelIdentity) -> Bool
    public func ensure(_ model: ModelIdentity, progress: ProgressHandler?) async throws
    public func prefetch(_ tier: Tier, progress: ProgressHandler?) async throws
    public func evict(_ model: ModelIdentity) async throws
    public func cacheSize() async -> Int
    public func cacheLocation() async -> URL
}
```

Cache lives at `~/Library/Caches/com.mvscollective.ForgeStudio/Models/` by default. Consumers can override the location (signage CLI uses a shared mount; media player uses the user cache).

Integrity check on every load: SHA-256 manifest distributed with the package, verified against downloaded bytes before deserialization. Corrupted files trigger automatic re-download with exponential backoff.

### 5.3 Required-resource surfacing

The CLI consumer wants to manage downloads explicitly. The media-player consumer wants the download to feel transparent. Both are supported via the same surface:

```swift
// Consumer asks: "what do I need before I can run this?"
let plan = ForgeStudio.requiredResources(for: .enhance, tier: .premium)
// plan.totalBytes: Int
// plan.models: [ModelIdentity]
// plan.missing: [ModelIdentity]  // not yet in cache
// plan.estimatedDownloadTime: TimeInterval?  // based on recent download speeds

// CLI uses this for "you need X GB; download now? [y/N]" prompts
// Media player uses this for progress UI before the user commits
```

When a consumer calls a task without first checking `requiredResources`, ForgeStudio surfaces the missing models via a typed error that includes the same plan, so consumer UI can drive the resolution. The consumer chooses whether to auto-download (media player) or fail-and-ask (CLI's default).

### 5.4 Storage hygiene

ForgeStudio publishes cache size and supports eviction by tier, by model, or by last-use timestamp. Eviction policy is consumer-driven; ForgeStudio does not auto-evict.

## 6. Task-oriented API

### 6.1 The four verbs

ForgeStudio v0.1 exposes four task verbs:

```swift
public enum Task {
    case enhance       // General-purpose quality improvement
    case upscale       // Resolution increase
    case restore       // Repair specific known degradations
    case batch         // Apply any of the above across many files
}
```

The verbs are deliberately coarse. Each verb has options that tune behavior without exposing model-level choices.

### 6.2 `enhance`

The default "make this look better" verb. Equivalent to "I have a client signage file that looks bad; make it look not-bad without changing the resolution."

```swift
public struct EnhanceOptions: Sendable {
    public var tier: TierSelection = .auto                 // .auto | .specific(Tier)
    public var preserveResolution: Bool = true             // No upscale unless asked
    public var artifactRemoval: Aggressiveness = .balanced // .light, .balanced, .aggressive
    public var denoiseStrength: Aggressiveness = .balanced
    public var preserveText: Bool = true                   // Signage default
    public var outputCodec: OutputCodec = .source          // .source, .hevc, .h264, .av1
    public var outputBitrate: Bitrate = .targetVMAF(95)    // VMAF target or bitrate
}

public func enhance(
    input: URL,
    output: URL,
    options: EnhanceOptions = .init(),
    progress: ProgressHandler? = nil
) async throws -> EnhanceResult
```

The `preserveText` flag is signage-specific. When true, ForgeStudio applies the text-aware loss path from Survey 2 (Pattern Recognition vol. 173) during any super-resolution sub-step, even if the user didn't request upscale (e.g., enhancement may internally upscale-then-downsample for noise reduction). When false, ForgeStudio uses the standard perceptual path.

### 6.3 `upscale`

Resolution increase with optional quality enhancement. Equivalent to "I have an old library video; make it 4K."

```swift
public struct UpscaleOptions: Sendable {
    public var tier: TierSelection = .auto
    public var scale: ScaleFactor                  // .x2, .x3, .x4, .targetResolution(W, H)
    public var preserveAspectRatio: Bool = true
    public var temporalConsistency: TemporalMode = .flowGuided  // .none, .flowGuided, .fullVideoModel
    public var preserveText: Bool = true
    public var outputCodec: OutputCodec = .hevc
    public var outputBitrate: Bitrate = .targetVMAF(95)
}
```

`temporalConsistency` is the lever for the SeedVR2-class vs per-frame trade. `.none` runs the upscaler frame-by-frame (fastest, can flicker). `.flowGuided` uses LiteFlowNet from ForgeUpscaler for temporal blending (the existing Forge path). `.fullVideoModel` routes to SeedVR2 at tiers that support it (`enhanced` and up).

### 6.4 `restore`

Targeted repair when the consumer knows what's broken.

```swift
public enum Degradation: Sendable {
    case mpeg2Era             // DVD-era encoding artifacts
    case heavyCompression     // Modern but over-compressed
    case sensorNoise          // Camera noise patterns
    case interlaced           // Interlace deinterlacing pass
    case chromaSubsampling    // 4:2:0 → 4:4:4 reconstruction
    case unknown              // Let ForgeStudio analyze and pick
}

public struct RestoreOptions: Sendable {
    public var tier: TierSelection = .auto
    public var degradations: [Degradation] = [.unknown]
    public var preserveText: Bool = true
    public var outputCodec: OutputCodec = .source
    public var outputBitrate: Bitrate = .targetVMAF(95)
}
```

When `degradations` includes `.unknown`, ForgeStudio runs a small analysis pass (using the quality oracle at the current tier) to classify the dominant degradations before picking the restoration pipeline.

### 6.5 `batch`

Wraps any of the above across many files. Mostly a convenience for the signage CLI use case.

```swift
public struct BatchInput: Sendable {
    public var files: [URL]
    public var task: BatchTask           // .enhance(EnhanceOptions), .upscale(...), .restore(...)
    public var outputStrategy: OutputStrategy  // .siblingFile(suffix:), .destinationDirectory(URL), .replaceInPlace(backupTo: URL?)
    public var continueOnError: Bool = true
}

public func batch(_ input: BatchInput, progress: BatchProgressHandler? = nil) async throws -> BatchResult
```

`BatchResult` includes per-file status, per-file quality metrics, and aggregate timings. The signage CLI uses this directly; the media player would only use it for multi-file user operations.

### 6.6 Progress reporting

Progress handlers receive structured updates, not strings:

```swift
public struct ProgressUpdate: Sendable {
    public var phase: Phase              // .probing, .downloading(ModelIdentity), .preparing, .processing(Double), .encoding, .finalizing
    public var overallFraction: Double   // 0.0 ... 1.0
    public var currentFrame: Int?
    public var totalFrames: Int?
    public var estimatedRemaining: TimeInterval?
    public var memoryPressure: MemoryPressure  // .nominal, .elevated, .critical
}
```

Memory pressure is surfaced so consumers can warn users when other apps may need to be closed.

## 7. Quality contract

ForgeStudio commits to specific quality outcomes per tier. These are the acceptance gates that prove the tier's value.

| Tier | enhance VMAF gain vs input | upscale x4 VMAF vs RRDBNet baseline | restore-MPEG2 PSNR gain vs FFmpeg-only | Notes |
|---|---|---|---|---|
| `base` | ≥3.0 VMAF | within 0.5 dB | ≥2.0 dB | Embedded path; meets all uses without download |
| `enhanced` | ≥5.0 VMAF | ≥+1.5 over base | ≥4.0 dB | Diffusion SR comes online |
| `premium` | ≥7.0 VMAF | ≥+1.0 over enhanced | ≥6.0 dB | Two-pass restoration; vision-encoder oracle |
| `ultra` | ≥1.0 VMAF over premium | ≥+0.5 over premium | ≥7.0 dB | Diminishing returns; for users who want maximum |

These targets become CI gates in the benchmark harness (reusing the Forge BenchmarkSchema v1.0 with a `forge_studio` top-level key extension). Any tier whose gates fail in a release candidate ships flagged as "preview" until the gap closes.

## 8. Consumer profiles

### 8.1 Signage CLI

The first consumer. Standalone binary, internal MVS Collective tool, runs against client deliverables.

```
forge-studio enhance ./client-files/*.mp4 --tier auto --output ./fixed/
forge-studio batch restore ./broken-batch.json --degradations mpeg2Era,chromaSubsampling --tier premium
forge-studio models prefetch --tier premium
forge-studio models list --installed
forge-studio models evict --older-than 30d
```

CLI is a separate target outside ForgeStudio itself (consistent with the thin-boundary principle). It lives at `github.com/mvscollective/forge-studio-cli` (or wherever MVS hosts internal tooling), depends on ForgeStudio as an SPM dependency, and provides:

- Argparse and command routing
- Path globbing and batch file format (JSON manifests)
- Progress rendering (terminal-friendly)
- Exit-code semantics for shell integration

### 8.2 MVS media player (planned)

Future consumer. Hosts ForgeStudio inside the existing media-player app. UI provides:

- Right-click → "Enhance" → tier picker (showing only available tiers)
- Settings pane for tier override defaults
- Background download manager visible to user
- Per-file progress in the playlist

The media player surfaces `ForgeStudio.HardwareCapabilities.probe()` results in an "About" pane so users understand why certain tiers are or aren't available.

### 8.3 Forge.app (future)

Possible eventual consumer. Forge currently has its own optimization path (the realtime track); a "send to ForgeStudio for high-quality export" option would let Forge users access offline quality when they don't need realtime. Out of scope for ForgeStudio v0.1.

## 9. Phasing

Implementation follows a four-phase plan that parallels (but is independent of) the Forge Coding Plan.

### Phase S.A — Foundation (~1 week)
- ForgeStudio SPM package scaffold; public API surface defined; all error types declared
- Hardware probe implementation; tier-mapping table in place
- WeightCache actor with download, integrity check, eviction
- ModelRegistry for embedded models; manifest format defined

### Phase S.B — `base` tier complete (~2-3 weeks)
- NAFNet width-32 8-block CoreML embedded (consumes Forge Phase B output)
- Real-ESRGAN MLX integration (consumes the existing themindstudio port)
- `enhance` and `upscale` task verbs working at `base` tier
- Signage CLI v0.1 ships consuming `base` tier only
- Benchmark harness wired; `base` tier gates pass

### Phase S.C — `enhanced` tier (~3 weeks)
- SeedVR2-3B integration via mflux (consumes xocialize Effort D, future)
- SigLIP2-base oracle integrated
- `restore` task verb working at `enhanced` tier
- Lazy-download UX validated through the CLI

### Phase S.D — `premium` and `ultra` tiers (~4 weeks)
- SeedVR2-7B integration
- MoonViT or alternative large oracle (subject to license review at integration time)
- Two-pass restoration pipelines
- `ultra` tier benchmark gates pass
- Media-player integration design begins (not implementation)

Total ForgeStudio v0.1 calendar: ~10-12 weeks of active work, designed to run alongside Forge Phase B/C/D/E and the xocialize-code Q3 track. The engineer rotates across all three (Forge, xocialize-code, ForgeStudio) using the same back-pressure rules already defined in the xocialize-code PRD §3.

## 10. License posture

ForgeStudio inherits MVS Collective's commercial-compatible policy. Every embedded or downloadable model must pass `LicensePolicy.commercial`. Specifically:

- All embedded models: Apache-2.0, MIT, or BSD-family
- All lazy-downloaded models: same requirement
- Training-data licenses documented per model card
- The MoonViT integration in `premium`/`ultra` is **gated on license diligence at integration time** — if the Kimi-VL family's commercial terms aren't permissive, a substitute oracle replaces it

ForgeStudio refuses to load a model with a `weightLicense` outside the permissive set, surfacing `ForgeStudioError.licenseViolation(model:license:)` to consumers. The consumer cannot override this; license enforcement is by design.

## 11. Out of scope (this PRD)

- UI of any kind (consumer responsibility)
- Cloud rendering or offload
- Realtime / streaming use cases (Forge handles these)
- iOS/iPadOS support (macOS arm64 only; iOS may follow if memory ceilings improve)
- Windows / Linux support
- Audio enhancement (separate track; xocialize-code audio packages remain audio-focused)
- Color grading or HDR-specific processing (future PRD)
- DRM-protected content handling (consumer responsibility)
- Cluster / multi-machine processing (single-machine only)

## 12. Open questions

- **MoonViT commercial terms.** Not verified at PRD time. The `premium`/`ultra` tiers are designed so MoonViT is replaceable without API change; SigLIP2-large is the fallback oracle if MoonViT's terms aren't suitable.
- **SeedVR2 integration timing.** mflux already has SeedVR2 working in MLX; xocialize-code Effort D would produce Swift bindings. ForgeStudio `enhanced`-and-up tiers depend on Effort D shipping. If Effort D slips, ForgeStudio caps at `base` tier longer than planned.
- **Default `tier: .auto` margin.** Currently spec'd as "one tier below ceiling." Real-world telemetry from the signage CLI may suggest a different default — e.g., on a 64 GB Pro, defaulting to `enhanced` rather than `premium` might be too conservative.
- **Progress granularity for diffusion paths.** Diffusion models produce many small steps; progress callbacks could fire 50+ times per frame. Consumer-friendly throttling policy needs validation against real UI consumers.
- **CLI vs library cache location.** Signage CLI on shared mounts, media player in user cache, but a single machine might run both. Whether the cache is shared (with proper file locks) or per-consumer is a decision for Phase S.A.

## 13. References

**Internal:**
- Forge PRD v0.3 (sibling, realtime track)
- Forge Coding Plan v1.0 (parallel phase structure)
- Forge-BenchmarkSchema-v1.0 (extended with `forge_studio` top-level key)
- ADR-0008 (lifts Forge Phase C freeze; does not affect ForgeStudio)
- xocialize-code Q3 2026 Dev Track PRD v0.1 (Effort A/B feed ForgeStudio base tier; future Effort D feeds enhanced+)
- Triple Survey (NR-IQA / Efficient SR / Neural Codecs) — model candidate sourcing

**Models referenced:**
- NAFNet — arXiv:2204.04676; `github.com/megvii-research/NAFNet` (MIT)
- Real-ESRGAN MLX — `huggingface.co/themindstudio/RealESRGAN-x4plus-mlx` (BSD-3-Clause)
- SeedVR2 — arXiv:2506.05301; `huggingface.co/ByteDance-Seed/SeedVR2-{3B,7B}` (Apache-2.0); MLX implementation in `filipstrand/mflux`
- SigLIP2 — `mlx-community/siglip2-base` (Apache-2.0)
- MoonViT — `huggingface.co/moonshotai/MoonViT-SO-400M` (license verification pending)
- OSEDiff — arXiv:2406.08177 (license blocker; not in v0.1)

---

## 14. First tasks for the engineer

1. Read this PRD in full plus the xocialize-code Q3 2026 Dev Track PRD §3 (rotation rules)
2. Create the `ForgeStudio` SPM package scaffold and the public API surface as Swift protocols (no implementations yet)
3. Land the `HardwareCapabilities.probe()` implementation and unit tests
4. Land the `WeightCache` actor with a stub model registry (no real models yet)
5. **STOP and report** the public API for review before any model integration work

After review, Phase S.B (the `base` tier) becomes the first active work block. It runs during Forge Phase B.3 NAFNet training (~4 days unattended) and uses Forge's own NAFNet weights as the embedded `base`-tier restoration backbone — no duplication of effort.

---

End of PRD.
