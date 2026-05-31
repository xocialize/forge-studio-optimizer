//
// BenchmarkSuite.swift
// ForgeOptimizer / Benchmark
//
// Actor that orchestrates one benchmark run end-to-end: probes host
// hardware/git/deps, accepts per-clip OptimizerRun / UpscalerRun
// records as the (future) runtime path produces them, evaluates the
// 7-gate catalog, and emits a single `BenchmarkReport`.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//
// RUNTIME PATH (Phase A.2 finalization):
// - `runOptimizerPass` drives one clip × one level through
//   FFmpegDecoder → PreprocessorFactory chain → NativeEncoder using
//   `BenchmarkRunner`. Per-frame timing, peak resident bytes,
//   PSNR/SSIM, and a VMAF subprocess produce a populated
//   `OptimizerRun`.
// - `runUpscalerPass` is wired to the same decode + encode glue but
//   currently returns `.failed` with a `failureReason` flagging the
//   missing SRVGGNet/RRDBNet weights (Phase C/D).
//

import Foundation

public enum BenchmarkSuiteError: Error, Sendable, CustomStringConvertible {
    case writeFailed(URL, Error)

    public var description: String {
        switch self {
        case .writeFailed(let url, let err):
            return "Failed to write benchmark report to \(url.path): \(err)"
        }
    }
}

/// Orchestrates one benchmark run.
///
/// `BenchmarkSuite` is an actor because it accumulates per-clip
/// run records concurrently from multiple optimization-level passes
/// (think `await taskGroup.addTask`). Per-clip state is internal;
/// callers interact through the public `runOptimizerPass` /
/// `runUpscalerPass` / `emit` API.
public actor BenchmarkSuite {

    // MARK: - Inputs

    public let runLabel: String
    public let registry: ModelRegistry
    public let corpus: Corpus
    public let notes: String?

    // MARK: - Runtime path

    /// The runner that owns the decode → preprocess → encode loop. Nil
    /// keeps the runtime paths stubbed (legacy behavior for tests that
    /// don't want to touch disk).
    private let runner: BenchmarkRunner?

    // MARK: - Probes (injectable for tests)

    private let hardwareProbe: HardwareProbe
    private let gitProbe: GitProbe
    private let dependencyProbe: DependencyProbe
    private let inventory: InventoryEnumerator
    private let evaluator: GateEvaluator

    // MARK: - Accumulated runs

    private var optimizerRuns: [OptimizerRun] = []
    private var upscalerRunsPlayback: [UpscalerRun] = []
    private var upscalerRunsExport: [UpscalerRun] = []
    private var upscalerRunsSignage: [UpscalerRun] = []

    /// Default initializer. Probes use sensible defaults; tests can
    /// substitute via the testing-friendly init below. `runner` is
    /// nil — the runtime path stays stubbed unless the caller wires
    /// a `BenchmarkRunner` via `init(..., runner:)`.
    public init(
        runLabel: String,
        registry: ModelRegistry,
        corpus: Corpus,
        notes: String? = nil,
        runner: BenchmarkRunner? = nil
    ) {
        self.init(
            runLabel: runLabel,
            registry: registry,
            corpus: corpus,
            notes: notes,
            runner: runner,
            hardwareProbe: HardwareProbe(),
            gitProbe: GitProbe(),
            dependencyProbe: DependencyProbe(),
            inventory: InventoryEnumerator.forgeOptimizerBundle(),
            evaluator: GateEvaluator()
        )
    }

    /// Test-friendly initializer: every probe is overridable so tests
    /// can pin hardware/git/dependency snapshots without touching the
    /// host machine.
    public init(
        runLabel: String,
        registry: ModelRegistry,
        corpus: Corpus,
        notes: String?,
        runner: BenchmarkRunner? = nil,
        hardwareProbe: HardwareProbe,
        gitProbe: GitProbe,
        dependencyProbe: DependencyProbe,
        inventory: InventoryEnumerator,
        evaluator: GateEvaluator
    ) {
        self.runLabel = runLabel
        self.registry = registry
        self.corpus = corpus
        self.notes = notes
        self.runner = runner
        self.hardwareProbe = hardwareProbe
        self.gitProbe = gitProbe
        self.dependencyProbe = dependencyProbe
        self.inventory = inventory
        self.evaluator = evaluator
    }

    // MARK: - Public surface — runtime path

    /// Run the ForgeOptimizer pipeline at the given level on the given
    /// clip and capture an `OptimizerRun` record.
    ///
    /// When a `BenchmarkRunner` was supplied at init, this drives the
    /// real runtime path (decode → preprocess chain → encode → measure).
    /// When `runner` is nil (the historical stub behavior, retained for
    /// unit tests), this emits a `.failed` placeholder.
    public func runOptimizerPass(
        level: OptimizerRun.OptimizationLevel,
        clipID: String,
        crf: Int? = nil
    ) async throws -> OptimizerRun {
        guard let clip = corpus.clips.first(where: { $0.id == clipID }) else {
            let run = OptimizerRun(
                clipID: clipID,
                optimizationLevel: level,
                resolution: "0x0",
                status: .failed,
                failureReason: "clip '\(clipID)' not found in corpus"
            )
            optimizerRuns.append(run)
            return run
        }

        let run: OptimizerRun
        if let runner = runner {
            if let crf = crf {
                run = await runner.runCompressionCRFPass(level: level, clip: clip, crf: crf)
            } else {
                run = await runner.runOptimizerPass(level: level, clip: clip)
            }
        } else {
            run = OptimizerRun(
                clipID: clipID,
                optimizationLevel: level,
                resolution: clip.resolution,
                status: .failed,
                failureReason: "BenchmarkSuite runtime path pending Phase A.2 finalization (depends on FFmpegXC build)"
            )
        }
        optimizerRuns.append(run)
        return run
    }

    /// Run a ForgeUpscaler tier on the given clip and capture an
    /// `UpscalerRun` record.
    ///
    /// **Back-compat path** — the original Phase A.2 entry point keyed by
    /// a freeform `tier: String`. `"playback"` routes through the runner's
    /// real upscaler implementation as the EfRLFN default (post-ADR-0006);
    /// `"export"` and `"signage"` continue to return `.failed` with a
    /// Phase C/D-scope reason. New callers should prefer
    /// `runPlaybackBackendPass(backend:scale:clipID:)` for explicit
    /// backend control.
    public func runUpscalerPass(
        tier: String,
        clipID: String
    ) async throws -> UpscalerRun {
        guard let clip = corpus.clips.first(where: { $0.id == clipID }) else {
            let run = UpscalerRun(
                clipID: clipID,
                inputResolution: "0x0",
                outputResolution: "0x0",
                scaleFactor: 2,
                status: .failed,
                failureReason: "clip '\(clipID)' not found in corpus"
            )
            recordUpscalerRun(run, tier: tier)
            return run
        }

        let run: UpscalerRun
        if let runner = runner {
            run = await runner.runUpscalerPass(tier: tier, clip: clip)
        } else {
            let outputRes = Self.scale2x(clip.resolution)
            run = UpscalerRun(
                clipID: clipID,
                inputResolution: clip.resolution,
                outputResolution: outputRes,
                scaleFactor: 2,
                status: .failed,
                failureReason: "BenchmarkSuite runtime path pending Phase A.2 finalization (depends on FFmpegXC build)"
            )
        }
        recordUpscalerRun(run, tier: tier)
        return run
    }

    /// Run an explicit playback backend on the given clip and capture
    /// an `UpscalerRun` record into the playback tier slot.
    ///
    /// Phase C.4 A/B entry point — pin one of the four backends
    /// (`.efrlfn`, `.srvggnetGeneral`, `.srvggnetGeneralWDN`,
    /// `.srvggnetAnime`) and drive a real upscaler pass. Returns
    /// `.failed` with a clear reason when the runtime path is unwired
    /// (no `BenchmarkRunner` injected at init) so unit tests that
    /// don't want disk I/O keep working.
    public func runPlaybackBackendPass(
        backend: BenchmarkRunner.PlaybackBackendID,
        scale: Int = 4,
        clipID: String,
        externalLRDir: URL? = nil
    ) async throws -> UpscalerRun {
        guard let clip = corpus.clips.first(where: { $0.id == clipID }) else {
            let outputRes = "0x0"
            let run = UpscalerRun(
                clipID: clipID,
                inputResolution: "0x0",
                outputResolution: outputRes,
                scaleFactor: scale,
                status: .failed,
                failureReason: "clip '\(clipID)' not found in corpus",
                backend: "\(backend.rawValue)-x\(scale)"
            )
            recordUpscalerRun(run, tier: "playback")
            return run
        }

        let run: UpscalerRun
        if let runner = runner {
            let externalLR = externalLRDir?.appendingPathComponent("\(clipID).mp4")
            run = await runner.runUpscalerPass(
                backend: backend, scale: scale, clip: clip, externalLR: externalLR)
        } else {
            let outputRes = BenchmarkRunner.scaleResolution(clip.resolution, factor: scale)
            run = UpscalerRun(
                clipID: clipID,
                inputResolution: clip.resolution,
                outputResolution: outputRes,
                scaleFactor: scale,
                status: .failed,
                failureReason: "BenchmarkSuite runtime path requires a BenchmarkRunner; not injected at init",
                backend: "\(backend.rawValue)-x\(scale)"
            )
        }
        recordUpscalerRun(run, tier: "playback")
        return run
    }

    /// File a populated `UpscalerRun` into the matching tier slot.
    /// Unknown tiers fall back to playback so the run is still recorded.
    private func recordUpscalerRun(_ run: UpscalerRun, tier: String) {
        switch tier {
        case "playback": upscalerRunsPlayback.append(run)
        case "export":   upscalerRunsExport.append(run)
        case "signage":  upscalerRunsSignage.append(run)
        default:         upscalerRunsPlayback.append(run)
        }
    }

    /// Manually append a fully-formed `OptimizerRun`. Used by the
    /// runtime path (once it lands) and by tests that synthesize runs.
    public func appendOptimizerRun(_ run: OptimizerRun) {
        optimizerRuns.append(run)
    }

    /// Manually append a fully-formed `UpscalerRun` to one of the
    /// three tiers.
    public func appendUpscalerRun(_ run: UpscalerRun, tier: String) {
        switch tier {
        case "playback": upscalerRunsPlayback.append(run)
        case "export":   upscalerRunsExport.append(run)
        case "signage":  upscalerRunsSignage.append(run)
        default: upscalerRunsPlayback.append(run)
        }
    }

    // MARK: - Emission

    /// Build a complete `BenchmarkReport` from the current state. Pure
    /// function over accumulated runs + the probes; safe to call any
    /// time, multiple times.
    public func emit() async throws -> BenchmarkReport {
        let hardware = hardwareProbe.snapshot()
        let git = gitProbe.snapshot() ?? GitInfo(
            sha: "0000000",
            branch: "(detached)",
            dirty: false,
            remoteURL: nil
        )
        let deps = dependencyProbe.snapshot()

        let manifests = await registry.inventory()
        let entries = inventory.enumerate(manifests: manifests)
        let bundleBytes = entries.reduce(0) { $0 + $1.sizeBytes }

        let optimizerResults = ForgeOptimizerResults(
            bundleBytes: bundleBytes,
            modelInventory: entries,
            runs: optimizerRuns
        )

        // The upscaler results block stays nil until at least one tier
        // has been exercised — preserves the schema's "minProperties:
        // 1" constraint on `pipeline_results` (optimizer is always
        // present, upscaler optional).
        let upscalerResults: ForgeUpscalerResults?
        if upscalerRunsPlayback.isEmpty && upscalerRunsExport.isEmpty && upscalerRunsSignage.isEmpty {
            upscalerResults = nil
        } else {
            upscalerResults = ForgeUpscalerResults(
                bundleBytes: 0,  // Upscaler bundle accounting is Phase C+/D work.
                modelInventory: [],
                tiers: ForgeUpscalerResults.Tiers(
                    playback: upscalerRunsPlayback.isEmpty ? nil : upscalerRunsPlayback,
                    export: upscalerRunsExport.isEmpty ? nil : upscalerRunsExport,
                    signage: upscalerRunsSignage.isEmpty ? nil : upscalerRunsSignage
                )
            )
        }

        let pipelineResults = PipelineResults(
            forgeOptimizer: optimizerResults,
            forgeUpscaler: upscalerResults
        )

        // Build a draft report so the evaluator can read corpus +
        // pipeline_results to compute actuals. The draft gates use an
        // empty results list; the final report swaps in evaluated
        // results.
        let draft = BenchmarkReport(
            runLabel: runLabel,
            notes: notes,
            git: git,
            hardware: hardware,
            dependencies: deps,
            corpus: corpus,
            pipelineResults: pipelineResults,
            gates: GateEvaluation(version: GateEvaluator.catalogVersion, results: [])
        )
        let gates = evaluator.evaluate(report: draft)

        return BenchmarkReport(
            schemaVersion: "1.0",
            reportID: draft.reportID,
            timestampUTC: draft.timestampUTC,
            runLabel: runLabel,
            notes: notes,
            git: git,
            hardware: hardware,
            dependencies: deps,
            corpus: corpus,
            pipelineResults: pipelineResults,
            gates: gates
        )
    }

    /// Write the report to disk as pretty-printed JSON with sorted
    /// keys + ISO-8601 dates. Filename convention is `benchmark-<runLabel>-<git_sha_short>.json`
    /// per schema §1 — the caller is responsible for choosing the URL;
    /// this method only enforces the encoding shape.
    public func write(report: BenchmarkReport, toFile url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(report)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw BenchmarkSuiteError.writeFailed(url, error)
        }
    }

    // MARK: - Helpers

    /// Compute a 2× scaled `WIDTHxHEIGHT` string. Returns `"0x0"` on
    /// malformed input — same shape as the input's fallback so the
    /// schema-pattern check still passes.
    static func scale2x(_ resolution: String) -> String {
        let parts = resolution.split(separator: "x")
        guard parts.count == 2,
              let w = Int(parts[0]),
              let h = Int(parts[1]) else {
            return "0x0"
        }
        return "\(w * 2)x\(h * 2)"
    }
}
