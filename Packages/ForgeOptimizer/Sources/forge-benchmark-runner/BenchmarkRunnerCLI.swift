//
// forge-benchmark-runner
//
// CLI entry point per Forge-BenchmarkSchema-v1.0.md §6. Drives a
// `BenchmarkSuite` against every clip in the corpus × every
// OptimizationLevel + every upscaler tier and emits one JSON report.
//
// Usage:
//   forge-benchmark-runner \
//     --corpus Forge/Tests/Corpus/manifest.json \
//     --output Docs/Benchmarks/benchmark-baseline-<run-label>-<sha>.json \
//     [--run-label baseline-v0.3-mlx-0.31.3] \
//     [--notes "Capture after MLX bump"] \
//     [--skip-vmaf]                          # disable VMAF subprocess
//     [--levels off,light,balanced]          # subset of levels
//     [--clip-ids id1,id2]                   # subset of clips
//     [--tiers playback,export,signage]      # upscaler tiers (legacy path)
//     [--playback-backend efrlfn|srvggnet-general|srvggnet-general-wdn
//                          |srvggnet-anime|all]   # Phase C.4 A/B
//     [--playback-scale 2|4]                       # default 4
//     [--upscaler-pass-only]                       # skip optimizer
//
// Exit codes:
//   0 = report emitted successfully
//   1 = report emitted as PARTIAL (one or more clips/levels failed)
//   2 = system error (missing args, file not found, parse error)
//
// Per Forge 2026 Q2 refresh plan §A.2 (initial)
//                            §C.4 (playback-backend A/B extension).
//

import ForgeOptimizer
import Foundation

@main
struct ForgeBenchmarkRunner {
    static func main() async {
        let args = CommandLine.arguments
        do {
            let opts = try parseArgs(args)
            try await run(opts)
        } catch let err as RunnerError {
            FileHandle.standardError.write(Data("forge-benchmark-runner: \(err.description)\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("forge-benchmark-runner: unexpected error: \(error)\n".utf8))
            exit(2)
        }
    }
}

// MARK: - Options

struct RunnerOptions {
    var corpus: URL
    var output: URL
    var runLabel: String
    var notes: String?
    var skipVMAF: Bool
    var levels: [OptimizerRun.OptimizationLevel]
    var clipIDFilter: Set<String>?  // nil = all clips
    var tiers: [String]
    /// Backends to A/B at the playback tier. Empty = legacy --tiers
    /// behavior only (no playback-backend pass). A single value pins
    /// that backend; passing `all` expands to every CaseIterable variant.
    var playbackBackends: [BenchmarkRunner.PlaybackBackendID]
    /// Upscale factor for the playback-backend pass. Defaults to 4;
    /// only EfRLFN admits 2 today (SRVGGNet variants will surface
    /// `.failed` at scale 2).
    var playbackScale: Int
    /// Skip optimizer-pass runs entirely. Useful for the C.4 A/B itself,
    /// which only needs the playback-backend numbers.
    var upscalerPassOnly: Bool
    /// External-LR mode (HD→master product test). When set, each clip's SR
    /// input is `<dir>/<clipID>.mp4` (e.g. a real Vimeo HD encode) instead of a
    /// clean ÷scale downscale; the clip is the HR reference. Only affects the
    /// playback-backend pass.
    var externalLRDir: URL?
}

enum RunnerError: Error, CustomStringConvertible {
    case missingRequired(String)
    case unknownFlag(String)
    case parseFailed(String)
    case fileNotFound(URL)

    var description: String {
        switch self {
        case .missingRequired(let f): return "missing required flag \(f) (try --help)"
        case .unknownFlag(let f):     return "unknown flag '\(f)' (try --help)"
        case .parseFailed(let d):     return "parse error: \(d)"
        case .fileNotFound(let url):  return "file not found: \(url.path)"
        }
    }
}

func parseArgs(_ argv: [String]) throws -> RunnerOptions {
    var corpus: URL?
    var output: URL?
    var runLabel: String?
    var notes: String?
    var skipVMAF = false
    var levels: [OptimizerRun.OptimizationLevel] =
        [.off, .light, .balanced, .aggressive, .maximum]
    var clipIDFilter: Set<String>?
    var tiers = ["playback", "export", "signage"]
    var playbackBackends: [BenchmarkRunner.PlaybackBackendID] = []
    var playbackScale: Int = 4
    var upscalerPassOnly = false
    var externalLRDir: URL?

    var i = 1
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--help", "-h":
            printUsage()
            exit(0)
        case "--corpus":
            guard i + 1 < argv.count else { throw RunnerError.missingRequired("--corpus") }
            corpus = URL(fileURLWithPath: argv[i + 1])
            i += 2
        case "--output":
            guard i + 1 < argv.count else { throw RunnerError.missingRequired("--output") }
            output = URL(fileURLWithPath: argv[i + 1])
            i += 2
        case "--run-label":
            guard i + 1 < argv.count else { throw RunnerError.missingRequired("--run-label") }
            runLabel = argv[i + 1]
            i += 2
        case "--notes":
            guard i + 1 < argv.count else { throw RunnerError.missingRequired("--notes") }
            notes = argv[i + 1]
            i += 2
        case "--skip-vmaf":
            skipVMAF = true
            i += 1
        case "--levels":
            guard i + 1 < argv.count else { throw RunnerError.missingRequired("--levels") }
            let raw = argv[i + 1].split(separator: ",")
            var parsed: [OptimizerRun.OptimizationLevel] = []
            for token in raw {
                let s = token.trimmingCharacters(in: .whitespaces)
                guard let level = OptimizerRun.OptimizationLevel(rawValue: s) else {
                    throw RunnerError.parseFailed("unknown level '\(s)'")
                }
                parsed.append(level)
            }
            levels = parsed
            i += 2
        case "--clip-ids":
            guard i + 1 < argv.count else { throw RunnerError.missingRequired("--clip-ids") }
            clipIDFilter = Set(argv[i + 1].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            i += 2
        case "--tiers":
            guard i + 1 < argv.count else { throw RunnerError.missingRequired("--tiers") }
            tiers = argv[i + 1].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            i += 2
        case "--playback-backend":
            guard i + 1 < argv.count else {
                throw RunnerError.missingRequired("--playback-backend")
            }
            playbackBackends = try parsePlaybackBackends(argv[i + 1])
            i += 2
        case "--playback-scale":
            guard i + 1 < argv.count else {
                throw RunnerError.missingRequired("--playback-scale")
            }
            guard let s = Int(argv[i + 1]), s == 2 || s == 4 else {
                throw RunnerError.parseFailed(
                    "--playback-scale must be 2 or 4 (got '\(argv[i + 1])')"
                )
            }
            playbackScale = s
            i += 2
        case "--upscaler-pass-only":
            upscalerPassOnly = true
            i += 1
        case "--external-lr-dir":
            guard i + 1 < argv.count else {
                throw RunnerError.missingRequired("--external-lr-dir")
            }
            externalLRDir = URL(fileURLWithPath: argv[i + 1])
            i += 2
        default:
            throw RunnerError.unknownFlag(arg)
        }
    }

    guard let c = corpus else { throw RunnerError.missingRequired("--corpus") }
    guard let o = output else { throw RunnerError.missingRequired("--output") }
    let label = runLabel ?? defaultRunLabel()

    if upscalerPassOnly && playbackBackends.isEmpty {
        throw RunnerError.parseFailed(
            "--upscaler-pass-only requires --playback-backend <name|all>"
        )
    }

    return RunnerOptions(
        corpus: c,
        output: o,
        runLabel: label,
        notes: notes,
        skipVMAF: skipVMAF,
        levels: levels,
        clipIDFilter: clipIDFilter,
        tiers: tiers,
        playbackBackends: playbackBackends,
        playbackScale: playbackScale,
        upscalerPassOnly: upscalerPassOnly,
        externalLRDir: externalLRDir
    )
}

/// Parse the `--playback-backend` argument value into a list of
/// `PlaybackBackendID` cases. Delegates to
/// `BenchmarkRunner.PlaybackBackendID.parseList(_:)` so the wire-format
/// rules live next to the enum (and are exercised by the library tests).
func parsePlaybackBackends(_ raw: String) throws -> [BenchmarkRunner.PlaybackBackendID] {
    do {
        return try BenchmarkRunner.PlaybackBackendID.parseList(raw)
    } catch let err as BenchmarkRunner.PlaybackBackendID.ParseError {
        throw RunnerError.parseFailed("--playback-backend: \(err.description)")
    }
}

func printUsage() {
    let usage = """
    forge-benchmark-runner — emit a Forge benchmark JSON report.

    Usage:
      forge-benchmark-runner --corpus <manifest.json> --output <report.json>
                             [--run-label <label>] [--notes <text>]
                             [--skip-vmaf]
                             [--levels off,light,balanced,aggressive,maximum]
                             [--clip-ids id1,id2,...]
                             [--tiers playback,export,signage]
                             [--playback-backend <name|csv|all>]
                             [--playback-scale 2|4]
                             [--upscaler-pass-only]

    Required:
      --corpus <manifest.json>   30-clip corpus manifest
                                 (Forge/Tests/Corpus/manifest.json)
      --output <report.json>     Where to write the report JSON

    Optional:
      --run-label <label>        Defaults to baseline-<UTC YYYYMMDDHHMM>
      --notes <text>             Free-form note recorded in the report
      --skip-vmaf                Disable VMAF subprocess (no ffmpeg-full)
      --levels <csv>             Subset of optimizer levels. Default: all 5
      --clip-ids <csv>           Subset of clip IDs. Default: every clip
      --tiers <csv>              Upscaler tiers (legacy path). Default:
                                 playback,export,signage. The "playback"
                                 tier currently routes to EfRLFN x4
                                 (post-ADR-0006 default) when no
                                 --playback-backend override is set.
      --playback-backend <id>    Phase C.4 A/B selector. One of:
                                   efrlfn                (EfRLFN, x2/x4)
                                   srvggnet-general      (SRVGGNet, x4)
                                   srvggnet-general-wdn  (SRVGGNet, x4)
                                   srvggnet-anime        (SRVGGNet, x4)
                                   all                   (every backend)
                                 May also pass a comma-separated subset.
                                 When set, the runner emits a separate
                                 UpscalerRun into pipeline_results
                                 .forge_upscaler.tiers.playback for each
                                 backend on each clip.
      --playback-scale <int>     Upscale factor for the C.4 A/B pass.
                                 2 or 4 (default 4). SRVGGNet variants
                                 at scale=2 report .failed with reason
                                 "only scale=4 supported for srvggnet-*
                                 (no x2 weights vendored)".
      --upscaler-pass-only       Skip optimizer-pass runs; only A/B the
                                 playback backends. Useful for the C.4
                                 A/B itself. Requires --playback-backend.
      --external-lr-dir <dir>    HD→master product test: use <dir>/<clipID>.mp4
                                 (a real HD encode) as the SR input instead of a
                                 clean ÷scale downscale. The clip is the HR
                                 reference; SR output is downscaled to the
                                 clip's resolution before VMAF.

    Dispatch matrix:
      (no --playback-backend)         optimizer + legacy --tiers passes
      --playback-backend X            optimizer + .X playback pass
      --playback-backend all          optimizer + every backend pass
      --upscaler-pass-only            (skip optimizer) playback pass only
        + --playback-backend X        \\

    Exit codes:
      0  report emitted, all clips × levels × backends succeeded
      1  report emitted as PARTIAL (one or more runs failed)
      2  system error (missing args, file not found, parse error)
    """
    print(usage)
}

/// Default run label: `baseline-<UTC YYYYMMDDHHMM>`. Stable across the
/// CI machine clock but unique enough to disambiguate.
func defaultRunLabel() -> String {
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmm"
    return "baseline-" + formatter.string(from: Date())
}

// MARK: - Run

func run(_ opts: RunnerOptions) async throws {
    // Validate inputs.
    let fm = FileManager.default
    guard fm.fileExists(atPath: opts.corpus.path) else {
        throw RunnerError.fileNotFound(opts.corpus)
    }

    // The clips directory is the manifest's sibling `clips/` per
    // fetch_corpus.sh layout. Allow the runner to fall back to that.
    let manifestDir = opts.corpus.deletingLastPathComponent()
    let clipsDir = manifestDir.appendingPathComponent("clips")

    // Load corpus + registry.
    let loader = CorpusLoader()
    let fullCorpus = try loader.load(from: opts.corpus)

    // Filter clips per --clip-ids (if any).
    let filteredCorpus: Corpus
    if let allow = opts.clipIDFilter {
        filteredCorpus = Corpus(
            name: fullCorpus.name,
            version: fullCorpus.version,
            clips: fullCorpus.clips.filter { allow.contains($0.id) }
        )
    } else {
        filteredCorpus = fullCorpus
    }

    let registry = ModelRegistry.makeBundled(policy: .development)
    // Drain the bundled-register Task before the suite starts inventorying.
    var manifests = await registry.inventory()
    for _ in 0..<10 where manifests.count < ModelRegistry.v0_3BaselineManifests.count {
        try? await Task.sleep(nanoseconds: 50_000_000)
        manifests = await registry.inventory()
    }

    let runner = BenchmarkRunner(
        clipsDirectory: clipsDir,
        computeVMAF: !opts.skipVMAF
    )

    let suite = BenchmarkSuite(
        runLabel: opts.runLabel,
        registry: registry,
        corpus: fullCorpus,  // keep the full corpus in the report
        notes: opts.notes,
        runner: runner
    )

    let stderr = FileHandle.standardError
    func log(_ msg: String) {
        stderr.write(Data((msg + "\n").utf8))
    }

    var anyPartialOrFailed = false

    // ── Optimizer pass ────────────────────────────────────────────────
    //
    // Skipped entirely when --upscaler-pass-only is set (the C.4 A/B
    // case). Otherwise: clips × levels.
    if !opts.upscalerPassOnly {
        let totalRuns = filteredCorpus.clips.count * opts.levels.count
        var runIndex = 0
        log("forge-benchmark-runner: \(filteredCorpus.clips.count) clips × \(opts.levels.count) levels = \(totalRuns) optimizer passes")

        for clip in filteredCorpus.clips {
            for level in opts.levels {
                runIndex += 1
                log("  [\(runIndex)/\(totalRuns)] \(clip.id) @ \(level.rawValue) …")
                let run = try await suite.runOptimizerPass(level: level, clipID: clip.id)
                switch run.status {
                case .success:
                    let fps = run.speed?.fpsMean.map { String(format: "%.1f fps", $0) } ?? "—"
                    log("       success: \(run.frameCount ?? 0) frames, \(fps)")
                case .partial:
                    anyPartialOrFailed = true
                    log("       partial: " + (run.failureReason ?? "(no reason)"))
                case .failed:
                    anyPartialOrFailed = true
                    log("       failed:  " + (run.failureReason ?? "(no reason)"))
                }
            }
        }
    } else {
        log("forge-benchmark-runner: --upscaler-pass-only set; skipping optimizer pass")
    }

    // ── Upscaler tiers — legacy path ──────────────────────────────────
    //
    // Honored only when --playback-backend was NOT set (the legacy
    // dispatch). When --playback-backend is in play we run the explicit
    // C.4 A/B path below instead to avoid double-running playback at
    // EfRLFN (the back-compat shim's default).
    if opts.playbackBackends.isEmpty {
        log("forge-benchmark-runner: \(filteredCorpus.clips.count) clips × \(opts.tiers.count) upscaler tiers (legacy)")
        for clip in filteredCorpus.clips {
            for tier in opts.tiers {
                let run = try await suite.runUpscalerPass(tier: tier, clipID: clip.id)
                if run.status != .success { anyPartialOrFailed = true }
            }
        }
    } else {
        // ── Playback-backend A/B ──────────────────────────────────────
        //
        // Pinned backend(s) × clips. Each row attributes itself to the
        // backend that produced it via UpscalerRun.backend.
        let totalAB = filteredCorpus.clips.count * opts.playbackBackends.count
        var abIndex = 0
        log("forge-benchmark-runner: \(filteredCorpus.clips.count) clips × \(opts.playbackBackends.count) playback backends = \(totalAB) upscaler passes (C.4 A/B)")
        for clip in filteredCorpus.clips {
            for backend in opts.playbackBackends {
                abIndex += 1
                log("  [\(abIndex)/\(totalAB)] \(clip.id) @ \(backend.rawValue)-x\(opts.playbackScale) …")
                let run = try await suite.runPlaybackBackendPass(
                    backend: backend,
                    scale: opts.playbackScale,
                    clipID: clip.id,
                    externalLRDir: opts.externalLRDir
                )
                switch run.status {
                case .success:
                    let fps = run.speed?.fpsMean.map { String(format: "%.1f fps", $0) } ?? "—"
                    log("       success: \(run.frameCount ?? 0) frames, \(fps)")
                case .partial:
                    anyPartialOrFailed = true
                    log("       partial: " + (run.failureReason ?? "(no reason)"))
                case .failed:
                    anyPartialOrFailed = true
                    log("       failed:  " + (run.failureReason ?? "(no reason)"))
                }
            }
        }
    }

    // Compute baseline ratios on optimizer compression metrics if .off
    // was included. This is the harness-side derivation per schema §4
    // CompressionMetrics.ratioVsBaseline — the suite itself doesn't
    // know which level is the baseline.
    let report = try await postProcessCompression(suite: suite)

    // Emit. If the run had partials, write a PARTIAL-prefixed file
    // name; otherwise honor the caller's --output exactly.
    let outputURL: URL
    if anyPartialOrFailed {
        outputURL = partialOutputURL(opts.output)
        log("forge-benchmark-runner: WARNING — at least one run was .partial or .failed")
        log("forge-benchmark-runner: writing PARTIAL report to \(outputURL.lastPathComponent)")
    } else {
        outputURL = opts.output
    }
    try await suite.write(report: report, toFile: outputURL)
    log("forge-benchmark-runner: wrote \(outputURL.path)")

    // Surface a one-line gate summary on stdout so CI logs can grep.
    let passed = report.gates.results.filter { $0.passed }.count
    let total = report.gates.results.count
    print("forge-benchmark-runner: gates \(passed)/\(total) passed; all_passed=\(report.gates.allPassed ?? false)")

    exit(anyPartialOrFailed ? 1 : 0)
}

/// Rebuild the report with `ratio_vs_baseline` / `savings_vs_baseline`
/// computed against the `.off` run for each clip. The suite emits the
/// runs in append order with `compression.ratioVsBaseline = nil`; this
/// post-pass walks the optimizer runs, looks up the `.off` baseline
/// per clip, and patches the derived ratios.
func postProcessCompression(suite: BenchmarkSuite) async throws -> BenchmarkReport {
    let report = try await suite.emit()

    guard let optimizer = report.pipelineResults.forgeOptimizer else {
        return report
    }

    // Map clip_id → baseline output bytes (from .off run).
    var baselineByClip: [String: Int] = [:]
    for run in optimizer.runs where run.optimizationLevel == .off {
        if let outBytes = run.compression?.outputBytes, outBytes > 0 {
            baselineByClip[run.clipID] = outBytes
        }
    }

    let patchedRuns: [OptimizerRun] = optimizer.runs.map { run in
        guard run.optimizationLevel != .off,
              let baseline = baselineByClip[run.clipID],
              baseline > 0,
              let comp = run.compression else {
            return run
        }
        let ratio = Double(comp.outputBytes) / Double(baseline)
        let savings = max(0.0, min(1.0, 1.0 - ratio))
        let newComp = CompressionMetrics(
            inputBytes: comp.inputBytes,
            outputBytes: comp.outputBytes,
            ratioVsBaseline: ratio,
            savingsVsBaseline: savings,
            encoder: comp.encoder,
            encoderSettings: comp.encoderSettings
        )
        return OptimizerRun(
            clipID: run.clipID,
            optimizationLevel: run.optimizationLevel,
            resolution: run.resolution,
            frameCount: run.frameCount,
            speed: run.speed,
            quality: run.quality,
            memory: run.memory,
            compression: newComp,
            status: run.status,
            failureReason: run.failureReason
        )
    }

    let patchedOptimizer = ForgeOptimizerResults(
        bundleBytes: optimizer.bundleBytes,
        modelInventory: optimizer.modelInventory,
        runs: patchedRuns
    )

    let patchedResults = PipelineResults(
        forgeOptimizer: patchedOptimizer,
        forgeUpscaler: report.pipelineResults.forgeUpscaler
    )

    // Re-evaluate gates against the patched compression metrics so the
    // `compression_*_min` actuals reflect the derived savings.
    let draft = BenchmarkReport(
        schemaVersion: report.schemaVersion,
        reportID: report.reportID,
        timestampUTC: report.timestampUTC,
        runLabel: report.runLabel,
        notes: report.notes,
        git: report.git,
        hardware: report.hardware,
        dependencies: report.dependencies,
        corpus: report.corpus,
        pipelineResults: patchedResults,
        gates: GateEvaluation(version: report.gates.version, results: [])
    )
    let gates = GateEvaluator().evaluate(report: draft)

    return BenchmarkReport(
        schemaVersion: report.schemaVersion,
        reportID: report.reportID,
        timestampUTC: report.timestampUTC,
        runLabel: report.runLabel,
        notes: report.notes,
        git: report.git,
        hardware: report.hardware,
        dependencies: report.dependencies,
        corpus: report.corpus,
        pipelineResults: patchedResults,
        gates: gates
    )
}

/// Replace `benchmark-<label>-<sha>.json` → `benchmark-PARTIAL-<sha>.json`.
/// Keeps the directory; rewrites the filename only.
func partialOutputURL(_ original: URL) -> URL {
    let dir = original.deletingLastPathComponent()
    let name = original.lastPathComponent
    // Heuristic: replace the `<label>` between `benchmark-` and the
    // first remaining hyphen with `PARTIAL`. Fall back to prefixing.
    if name.hasPrefix("benchmark-") {
        let body = String(name.dropFirst("benchmark-".count))
        if let dashIdx = body.firstIndex(of: "-") {
            let tail = body[dashIdx...]
            return dir.appendingPathComponent("benchmark-PARTIAL\(tail)")
        }
    }
    return dir.appendingPathComponent("PARTIAL-\(name)")
}
