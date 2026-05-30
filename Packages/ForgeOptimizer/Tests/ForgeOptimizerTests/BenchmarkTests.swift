//
// BenchmarkTests.swift
// ForgeOptimizer / Benchmark
//
// Tests for the Phase A.2 BenchmarkSuite framework.
//
// Notes:
// - The VMAF subprocess path is not exercised here (requires ffmpeg-full
//   + actual video files). Phase A.2's deliverable is the schema +
//   probe surface; VMAF integration is covered when the runtime path
//   lands.
// - PSNR / SSIM on CVPixelBuffer are also out of scope for these
//   compile-time tests because pixel-buffer creation needs CoreVideo
//   on a Metal-backed runtime; tested in Xcode-driven integration.
// - The Phase C.4 playback-backend A/B path does NOT exercise MLX at
//   runtime here for the same Metal-library reason that gates NAFNet
//   and EfRLFN tests (see CLAUDE.md "ForgeOptimizer / ForgeUpscaler
//   MLX tests" note). The CLI-runnable coverage validates argument
//   parsing, the PlaybackBackendID round-trip, and the materialization
//   / scale-validation gates that fail fast before any MLX call.
//
// Per Forge 2026 Q2 refresh plan §A.2, §C.4.
//

import Testing
import Foundation
@testable import ForgeOptimizer

@Suite("Benchmark")
struct BenchmarkTests {

    // MARK: - Schema round-trip (minimal)

    @Test("Minimal BenchmarkReport round-trips encode → decode without loss")
    func minimalReportRoundTrips() throws {
        let original = Self.minimalReport()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(BenchmarkReport.self, from: data)

        #expect(restored.schemaVersion == original.schemaVersion)
        #expect(restored.reportID == original.reportID)
        #expect(restored.runLabel == original.runLabel)
        #expect(restored.git.sha == original.git.sha)
        #expect(restored.git.branch == original.git.branch)
        #expect(restored.git.dirty == original.git.dirty)
        #expect(restored.hardware.chip == original.hardware.chip)
        #expect(restored.hardware.modelIdentifier == original.hardware.modelIdentifier)
        #expect(restored.hardware.memoryGB == original.hardware.memoryGB)
        #expect(restored.hardware.thermalState == original.hardware.thermalState)
        #expect(restored.dependencies.mlxVersion == original.dependencies.mlxVersion)
        #expect(restored.corpus.name == original.corpus.name)
        #expect(restored.corpus.clips.count == original.corpus.clips.count)
        #expect(restored.pipelineResults.forgeOptimizer?.bundleBytes == original.pipelineResults.forgeOptimizer?.bundleBytes)
        #expect(restored.gates.results.count == original.gates.results.count)
    }

    // MARK: - Schema §3 example round-trip

    @Test("Schema §3 example report decodes cleanly")
    func section3ExampleRoundTrips() throws {
        guard let data = Self.section3ExampleJSON.data(using: .utf8) else {
            Issue.record("Could not encode example JSON to UTF-8")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchmarkReport.self, from: data)

        #expect(report.schemaVersion == "1.0")
        #expect(report.runLabel == "baseline-v0.3-mlx-0.31.2")
        #expect(report.hardware.chip == "M4 Pro")
        #expect(report.hardware.memoryGB == 64.0)
        #expect(report.dependencies.mlxVersion == "0.31.2")
        #expect(report.corpus.clips.count == 2)
        #expect(report.pipelineResults.forgeOptimizer?.modelInventory.count == 6)
        #expect(report.pipelineResults.forgeOptimizer?.runs.count == 2)
        #expect(report.pipelineResults.forgeUpscaler?.tiers.playback?.count == 1)
        #expect(report.pipelineResults.forgeUpscaler?.tiers.export?.count == 1)
        #expect(report.gates.results.count == 7)

        // Re-encode and re-decode to verify round-trip preserves data.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let reEncoded = try encoder.encode(report)
        let restored = try decoder.decode(BenchmarkReport.self, from: reEncoded)
        #expect(restored.runLabel == report.runLabel)
        #expect(restored.gates.results.first?.gateID == report.gates.results.first?.gateID)
    }

    // MARK: - HardwareProbe

    @Test("HardwareProbe returns plausible values")
    func hardwareProbeReturnsSaneValues() {
        let snapshot = HardwareProbe().snapshot()
        #expect(!snapshot.chip.isEmpty)
        #expect(!snapshot.modelIdentifier.isEmpty)
        #expect(snapshot.memoryGB > 0)
        #expect(!snapshot.osVersion.isEmpty)
    }

    @Test("HardwareProbe chip parser strips Apple prefix")
    func chipParserStripsApplePrefix() {
        #expect(HardwareProbe.parseChip("Apple M5 Max") == "M5 Max")
        #expect(HardwareProbe.parseChip("Apple M4 Pro") == "M4 Pro")
        #expect(HardwareProbe.parseChip("M4 Pro") == "M4 Pro")
        #expect(HardwareProbe.parseChip("Apple M5") == "M5")
        #expect(HardwareProbe.parseChip("Apple M5 Ultra") == "M5 Ultra")
    }

    // MARK: - GitProbe

    @Test("GitProbe returns a sha and branch when run inside the worktree")
    func gitProbeWorksInWorktree() {
        // The package's source tree is the worktree, so probe relative
        // to this file's directory.
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let probe = GitProbe(workingDirectory: here)
        if let snapshot = probe.snapshot() {
            #expect(!snapshot.sha.isEmpty)
            #expect(snapshot.sha.count >= 7)
            #expect(!snapshot.branch.isEmpty)
        } else {
            // CI may run outside a git checkout (tarball, etc.); accept
            // nil rather than failing the suite. The probe is still
            // exercised.
            #expect(Bool(true))
        }
    }

    // MARK: - CorpusLoader

    @Test("CorpusLoader finds 30 clips in Forge/Tests/Corpus/manifest.json")
    func corpusLoaderReads30Clips() throws {
        let manifestURL = Self.locateManifest()
        guard let url = manifestURL else {
            Issue.record("Could not locate Forge/Tests/Corpus/manifest.json relative to test file")
            return
        }
        let corpus = try CorpusLoader().load(from: url)
        #expect(corpus.clips.count == 30)
        #expect(corpus.name == "forge-30clip-eval")
        // Validate the category distribution per ADR 0001 §Decision 3:
        // 10 general / 10 signage / 10 legacy.
        let general = corpus.clips.filter { $0.category == .general }.count
        let signage = corpus.clips.filter { $0.category == .signage }.count
        let legacy = corpus.clips.filter { $0.category == .legacy }.count
        #expect(general == 10)
        #expect(signage == 10)
        #expect(legacy == 10)
    }

    // MARK: - GateEvaluator

    @Test("GateEvaluator emits 5 gates (realtime gates removed, ADR-0009)")
    func gateEvaluatorEmitsFiveGates() {
        let report = Self.minimalReport()
        let evaluation = GateEvaluator().evaluate(report: report)
        #expect(evaluation.results.count == 5)
        #expect(evaluation.version == GateEvaluator.catalogVersion)
        // All 5 quality/size/compression gate IDs present; the two realtime
        // throughput gates were removed per ADR-0009.
        let ids = Set(evaluation.results.map { $0.gateID })
        let expected: Set<String> = [
            "bundle_size_max",
            "vmaf_balanced_min",
            "compression_balanced_min",
            "compression_signage_max_min",
            "quality_regressor_srcc_min",
        ]
        #expect(ids == expected)
    }

    // The two hardware-required-gate tests (skip / match on chip) were removed
    // with the realtime gates per ADR-0009 — they exercised
    // `throughput_balanced_m4pro_1080p`, the only catalog gate that carried a
    // `hardwareRequired`. The GateDefinition.hardwareRequired skip mechanism in
    // GateEvaluator is retained for a future hardware-gated metric; re-add
    // coverage when one lands.

    @Test("GateEvaluator comparisons honor tolerance")
    func gateEvaluatorTolerance() {
        // gte with tolerance: actual = target - slack still passes.
        #expect(GateEvaluator.compare(actual: 0.89, target: 0.90, comparison: .gte, tolerance: 0.05) == true)
        #expect(GateEvaluator.compare(actual: 0.80, target: 0.90, comparison: .gte, tolerance: 0.05) == false)
        // lte with tolerance:
        #expect(GateEvaluator.compare(actual: 12_500_000, target: 12_000_000, comparison: .lte, tolerance: 1_000_000) == true)
    }

    // MARK: - InventoryEnumerator

    @Test("InventoryEnumerator emits 6 entries for v0.3 baseline")
    func inventoryEnumeratorEmitsBaseline() async {
        let registry = ModelRegistry.makeBundled(policy: .development)
        // Synchronization: makeBundled fires an unstructured Task to
        // register; await an inventory call to drain that task.
        // First call may race the register Task; wait for completion
        // by yielding a few times.
        var manifests: [ModelManifest] = []
        for _ in 0..<10 {
            manifests = await registry.inventory()
            if manifests.count == ModelRegistry.v0_3BaselineManifests.count { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(manifests.count == 6)
        let enumerator = InventoryEnumerator.forgeOptimizerBundle()
        let entries = enumerator.enumerate(manifests: manifests)
        #expect(entries.count == 6)
        // Every entry has a non-empty implementation name.
        for entry in entries {
            #expect(!entry.implementation.isEmpty)
        }
        // SPDX strings should round-trip cleanly.
        let licenses = Set(entries.map { $0.spdxLicense })
        #expect(licenses.contains("Proprietary"))
        #expect(licenses.contains("Proprietary-Research"))
    }

    // MARK: - BenchmarkSuite end-to-end (stubbed path)

    @Test("BenchmarkSuite.emit produces a complete report with the stubbed runtime")
    func benchmarkSuiteEmitsCompleteReport() async throws {
        let corpus = Self.tinyCorpus()
        let registry = ModelRegistry.makeBundled(policy: .development)
        let suite = BenchmarkSuite(runLabel: "test-emit", registry: registry, corpus: corpus, notes: "harness sanity")

        // Exercise the stubbed runtime path so the runs list is non-empty.
        _ = try await suite.runOptimizerPass(level: .balanced, clipID: corpus.clips[0].id)
        _ = try await suite.runUpscalerPass(tier: "playback", clipID: corpus.clips[0].id)

        let report = try await suite.emit()
        #expect(report.runLabel == "test-emit")
        #expect(report.gates.results.count == 5)  // realtime gates removed (ADR-0009)
        #expect(report.pipelineResults.forgeOptimizer?.runs.count == 1)
        // Stubbed runs are .failed with the expected reason.
        let run = report.pipelineResults.forgeOptimizer?.runs.first
        #expect(run?.status == .failed)
        #expect(run?.failureReason?.contains("FFmpegXC") == true)
    }

    // MARK: - BenchmarkRunner (real runtime path)

    @Test("BenchmarkRunner returns .failed with a clear reason on missing clip file")
    func benchmarkRunnerHandlesMissingClipFile() async {
        // Point the runner at a directory that exists but doesn't
        // contain the target clip — the runner must produce a
        // schema-stable .failed record, not crash.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let runner = BenchmarkRunner(clipsDirectory: tmp, computeVMAF: false)
        let clip = CorpusClip(
            id: "does-not-exist",
            category: .general,
            subcategory: "film",
            resolution: "1920x1080",
            frameRate: 30.0,
            durationS: 1.0,
            codec: "h264",
            sha256: String(repeating: "0", count: 64)
        )
        let run = await runner.runOptimizerPass(level: .light, clip: clip)
        #expect(run.status == .failed)
        #expect(run.failureReason?.contains("not materialized") == true)
        #expect(run.optimizationLevel == .light)
        #expect(run.resolution == "1920x1080")
    }

    @Test("BenchmarkRunner.runUpscalerPass(tier:) routes \"playback\" through the SRVGGNet-general default and reports clip not materialized")
    func benchmarkRunnerUpscalerLegacyTierRoutesToEfRLFN() async {
        // Phase C.4 replaced the Phase A.2 stub: tier "playback" now
        // routes through PlaybackUpscaler(backend: .efrlfn(scale: 4))
        // per ADR-0006. With no clip file on disk, the runner returns
        // a schema-stable .failed row carrying the materialization
        // reason and the EfRLFN x4 backend tag.
        let runner = BenchmarkRunner(
            clipsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            computeVMAF: false
        )
        let clip = CorpusClip(
            id: "any-clip",
            category: .general,
            subcategory: "film",
            resolution: "1920x1080",
            frameRate: 30.0,
            durationS: 1.0,
            codec: "h264",
            sha256: String(repeating: "0", count: 64)
        )
        let run = await runner.runUpscalerPass(tier: "playback", clip: clip)
        #expect(run.status == .failed)
        #expect(run.failureReason?.contains("not materialized") == true)
        #expect(run.scaleFactor == 4)
        #expect(run.outputResolution == "7680x4320")
        #expect(run.backend == "srvggnet-general-x4")  // C.4 winner (ADR-0008)
    }

    @Test("BenchmarkRunner.runUpscalerPass(tier:) keeps the Phase C/D reason for \"export\" / \"signage\"")
    func benchmarkRunnerUpscalerLegacyTierFallthroughForUnwiredTiers() async {
        let runner = BenchmarkRunner(
            clipsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            computeVMAF: false
        )
        let clip = CorpusClip(
            id: "any-clip",
            category: .general,
            subcategory: "film",
            resolution: "1920x1080",
            frameRate: 30.0,
            durationS: 1.0,
            codec: "h264",
            sha256: String(repeating: "0", count: 64)
        )
        for tier in ["export", "signage"] {
            let run = await runner.runUpscalerPass(tier: tier, clip: clip)
            #expect(run.status == .failed)
            #expect(run.failureReason?.contains("not yet wired") == true)
            #expect(run.scaleFactor == 2)
            #expect(run.backend == nil)
        }
    }

    // MARK: - Playback-backend pass (Phase C.4 A/B)

    @Test("runUpscalerPass(backend:scale:clip:) returns .failed when the clip isn't materialized")
    func benchmarkRunnerPlaybackBackendHandlesMissingClipFile() async {
        let runner = BenchmarkRunner(
            clipsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            computeVMAF: false
        )
        let clip = CorpusClip(
            id: "does-not-exist",
            category: .general,
            subcategory: "film",
            resolution: "1920x1080",
            frameRate: 30.0,
            durationS: 1.0,
            codec: "h264",
            sha256: String(repeating: "0", count: 64)
        )
        let run = await runner.runUpscalerPass(backend: .efrlfn, scale: 4, clip: clip)
        #expect(run.status == .failed)
        #expect(run.failureReason?.contains("not materialized") == true)
        #expect(run.inputResolution == "1920x1080")
        #expect(run.outputResolution == "7680x4320")
        #expect(run.scaleFactor == 4)
        #expect(run.backend == "efrlfn-x4")
    }

    @Test("runUpscalerPass(backend:scale:clip:) rejects scale=2 for SRVGGNet variants with a clear reason")
    func benchmarkRunnerPlaybackBackendRejectsUnsupportedScale() async {
        let runner = BenchmarkRunner(
            clipsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            computeVMAF: false
        )
        let clip = CorpusClip(
            id: "any-clip",
            category: .general,
            subcategory: "film",
            resolution: "1920x1080",
            frameRate: 30.0,
            durationS: 1.0,
            codec: "h264",
            sha256: String(repeating: "0", count: 64)
        )
        let srvggnetVariants: [BenchmarkRunner.PlaybackBackendID] = [
            .srvggnetGeneral, .srvggnetGeneralWDN, .srvggnetAnime,
        ]
        for backend in srvggnetVariants {
            let run = await runner.runUpscalerPass(backend: backend, scale: 2, clip: clip)
            #expect(run.status == .failed)
            #expect(run.failureReason?.contains("only scale=4 supported") == true)
            #expect(run.scaleFactor == 2)
            #expect(run.backend == "\(backend.rawValue)-x2")
        }
    }

    @Test("PlaybackBackendID round-trips Codable for all 4 variants")
    func playbackBackendIDRoundTripsCodable() throws {
        let all = BenchmarkRunner.PlaybackBackendID.allCases
        #expect(all.count == 4)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for id in all {
            let data = try encoder.encode(id)
            let restored = try decoder.decode(BenchmarkRunner.PlaybackBackendID.self, from: data)
            #expect(restored == id)
        }
        // Raw-value round-trip — the wire format the CLI parses.
        #expect(BenchmarkRunner.PlaybackBackendID(rawValue: "efrlfn") == .efrlfn)
        #expect(BenchmarkRunner.PlaybackBackendID(rawValue: "srvggnet-general") == .srvggnetGeneral)
        #expect(BenchmarkRunner.PlaybackBackendID(rawValue: "srvggnet-general-wdn") == .srvggnetGeneralWDN)
        #expect(BenchmarkRunner.PlaybackBackendID(rawValue: "srvggnet-anime") == .srvggnetAnime)
        #expect(BenchmarkRunner.PlaybackBackendID(rawValue: "garbage") == nil)
    }

    @Test("PlaybackBackendID.toPlaybackBackend maps cleanly for all 4 variants")
    func playbackBackendIDMapsToForgeUpscalerBackend() {
        // Each variant must produce the matching PlaybackUpscaler.Backend
        // case at the requested scale. Verified by round-tripping each
        // mapping back through a string representation (.efrlfn ->
        // "efrlfn(scale: 4)" etc.) since the Backend enum isn't Equatable.
        let scale = 4
        let cases: [(BenchmarkRunner.PlaybackBackendID, String)] = [
            (.efrlfn,              "efrlfn(scale: \(scale))"),
            (.srvggnetGeneral,     "srvggnetGeneral(scale: \(scale))"),
            (.srvggnetGeneralWDN,  "srvggnetGeneralWDN(scale: \(scale))"),
            (.srvggnetAnime,       "srvggnetAnime(scale: \(scale))"),
        ]
        for (id, expected) in cases {
            let mapped = id.toPlaybackBackend(scale: scale)
            #expect(String(describing: mapped) == expected)
        }
    }

    @Test("PlaybackBackendID.supportsScale gates SRVGGNet at scale=2")
    func playbackBackendIDSupportsScale() {
        // EfRLFN accepts both scales (the x2 wrapper is gated at the
        // tier init, not at the identifier).
        #expect(BenchmarkRunner.PlaybackBackendID.efrlfn.supportsScale(2) == true)
        #expect(BenchmarkRunner.PlaybackBackendID.efrlfn.supportsScale(4) == true)
        // SRVGGNet variants ship x4-only.
        for id in [BenchmarkRunner.PlaybackBackendID.srvggnetGeneral,
                   .srvggnetGeneralWDN,
                   .srvggnetAnime] {
            #expect(id.supportsScale(2) == false)
            #expect(id.supportsScale(4) == true)
        }
    }

    // MARK: - CLI arg parsing

    @Test("PlaybackBackendID.parseList handles single backends, comma lists, and 'all'")
    func playbackBackendIDParseList() throws {
        // Single backend — the most common case (`--playback-backend efrlfn`).
        let single = try BenchmarkRunner.PlaybackBackendID.parseList("efrlfn")
        #expect(single == [.efrlfn])

        let single2 = try BenchmarkRunner.PlaybackBackendID.parseList("srvggnet-general")
        #expect(single2 == [.srvggnetGeneral])

        // 'all' expands to every CaseIterable variant in declaration order.
        let all = try BenchmarkRunner.PlaybackBackendID.parseList("all")
        #expect(all == BenchmarkRunner.PlaybackBackendID.allCases)
        #expect(all.count == 4)

        // Comma-separated subset preserves order.
        let pair = try BenchmarkRunner.PlaybackBackendID.parseList("efrlfn,srvggnet-general")
        #expect(pair == [.efrlfn, .srvggnetGeneral])

        // Whitespace tolerance — `--playback-backend "efrlfn, srvggnet-general"`.
        let padded = try BenchmarkRunner.PlaybackBackendID.parseList("  efrlfn , srvggnet-anime ")
        #expect(padded == [.efrlfn, .srvggnetAnime])
    }

    @Test("PlaybackBackendID.parseList rejects unknown names and empty values")
    func playbackBackendIDParseListRejectsGarbage() {
        // Unknown name → .unknownName with the offending token.
        do {
            _ = try BenchmarkRunner.PlaybackBackendID.parseList("rrdbnet")
            Issue.record("expected parseList to throw on unknown name")
        } catch let err as BenchmarkRunner.PlaybackBackendID.ParseError {
            #expect(err == .unknownName("rrdbnet"))
            #expect(err.description.contains("efrlfn"))
        } catch {
            Issue.record("expected ParseError, got \(error)")
        }
        // Empty → .empty.
        do {
            _ = try BenchmarkRunner.PlaybackBackendID.parseList("")
            Issue.record("expected parseList to throw on empty value")
        } catch let err as BenchmarkRunner.PlaybackBackendID.ParseError {
            #expect(err == .empty)
        } catch {
            Issue.record("expected ParseError, got \(error)")
        }
    }

    @Test("BenchmarkRunner percentile helper matches numpy linear interpolation")
    func benchmarkRunnerPercentile() {
        let xs: [Double] = [10, 20, 30, 40, 50]
        #expect(BenchmarkRunner.percentile(xs, 0.5) == 30.0)
        #expect(BenchmarkRunner.percentile(xs, 0.0) == 10.0)
        #expect(BenchmarkRunner.percentile(xs, 1.0) == 50.0)
        // 0.95 of a 5-element array → position 3.8 → 40*(1-0.8) + 50*0.8 = 48
        #expect(abs(BenchmarkRunner.percentile(xs, 0.95) - 48.0) < 1e-9)
    }

    @Test("BenchmarkRunner mapToFormatBridgeLevel covers all 5 levels")
    func benchmarkRunnerLevelMapping() {
        #expect(BenchmarkRunner.mapToFormatBridgeLevel(.off) == .off)
        #expect(BenchmarkRunner.mapToFormatBridgeLevel(.light) == .light)
        #expect(BenchmarkRunner.mapToFormatBridgeLevel(.balanced) == .balanced)
        #expect(BenchmarkRunner.mapToFormatBridgeLevel(.aggressive) == .aggressive)
        #expect(BenchmarkRunner.mapToFormatBridgeLevel(.maximum) == .maximum)
    }

    @Test("BenchmarkRunner scaleResolution doubles dimensions")
    func benchmarkRunnerScaleResolution() {
        #expect(BenchmarkRunner.scaleResolution("1920x1080", factor: 2) == "3840x2160")
        #expect(BenchmarkRunner.scaleResolution("1920x1080", factor: 4) == "7680x4320")
        #expect(BenchmarkRunner.scaleResolution("garbage", factor: 2) == "0x0")
    }

    // MARK: - Helpers

    private static func minimalReport(chip: String = "M5 Max") -> BenchmarkReport {
        BenchmarkReport(
            schemaVersion: "1.0",
            reportID: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
            timestampUTC: Date(timeIntervalSince1970: 1_700_000_000),
            runLabel: "test-minimal",
            notes: "minimal round-trip",
            git: GitInfo(sha: "abc1234", branch: "test", dirty: false, remoteURL: nil),
            hardware: HardwareInfo(
                modelIdentifier: "Mac16,2",
                chip: chip,
                cpuCores: 14,
                gpuCores: nil,
                memoryGB: 128.0,
                osVersion: "macOS 15.5",
                thermalState: .nominal,
                onBattery: false
            ),
            dependencies: Dependencies(
                mlxVersion: "0.31.3",
                mlxSwiftVersion: "0.31.3",
                swiftVersion: "swift-driver",
                xcodeVersion: "16.4",
                ffmpegVersion: "n7.1",
                coremlRuntime: nil
            ),
            corpus: tinyCorpus(),
            pipelineResults: PipelineResults(
                forgeOptimizer: ForgeOptimizerResults(
                    bundleBytes: 6_000_000,
                    modelInventory: [],
                    runs: []
                ),
                forgeUpscaler: nil
            ),
            gates: GateEvaluation(version: "v1.0", allPassed: false, results: [])
        )
    }

    private static func tinyCorpus() -> Corpus {
        Corpus(
            name: "test-corpus",
            version: "1.0",
            clips: [
                CorpusClip(
                    id: "test-clip-01",
                    category: .general,
                    subcategory: "film",
                    resolution: "1920x1080",
                    frameRate: 24.0,
                    durationS: 10.0,
                    codec: "h264",
                    sha256: String(repeating: "a", count: 64)
                )
            ]
        )
    }

    /// Walk up from the test file to find `Forge/Tests/Corpus/manifest.json`.
    static func locateManifest() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir
                .appendingPathComponent("Forge")
                .appendingPathComponent("Tests")
                .appendingPathComponent("Corpus")
                .appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Schema §3 example (verbatim from Docs/Forge-BenchmarkSchema-v1.0.md)

    static let section3ExampleJSON = #"""
    {
      "schema_version": "1.0",
      "report_id": "0193D7E2-4A8B-7C1D-9E3F-0A1B2C3D4E5F",
      "timestamp_utc": "2026-05-26T18:30:00Z",
      "run_label": "baseline-v0.3-mlx-0.31.2",
      "notes": "First baseline capture after MLX bump from 0.30.4 to 0.31.2 (Phase A.1). Compare against baseline-v0.3-mlx-0.30.4 to validate that 3D-conv speedup is real and nothing regressed.",
      "git": {
        "sha": "a1b2c3d4e5f6789012345678901234567890abcd",
        "branch": "feature/forge-2026-q2-refresh",
        "dirty": false,
        "remote_url": "https://github.com/mvscollective/forge"
      },
      "hardware": {
        "model_identifier": "Mac15,9",
        "chip": "M4 Pro",
        "cpu_cores": 12,
        "gpu_cores": 16,
        "memory_gb": 64,
        "os_version": "macOS 15.5",
        "thermal_state": "nominal",
        "on_battery": false
      },
      "dependencies": {
        "mlx_version": "0.31.2",
        "mlx_swift_version": "0.31.2",
        "swift_version": "6.0",
        "xcode_version": "16.4",
        "ffmpeg_version": "n7.1",
        "coreml_runtime": "8.0"
      },
      "corpus": {
        "name": "forge-30clip-eval",
        "version": "1.0",
        "clips": [
          {
            "id": "general-film-01",
            "category": "general",
            "subcategory": "film",
            "resolution": "1920x1080",
            "frame_rate": 23.976,
            "duration_s": 30.5,
            "codec": "h264",
            "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
          },
          {
            "id": "signage-static-04",
            "category": "signage",
            "subcategory": "static-logo",
            "resolution": "1920x1080",
            "frame_rate": 30.0,
            "duration_s": 60.0,
            "codec": "h264",
            "sha256": "f1d2d2f924e986ac86fdf7b36c94bcdf32beec15c1c6b1de54f97aabe9b8a3c4"
          }
        ]
      },
      "pipeline_results": {
        "forge_optimizer": {
          "bundle_bytes": 14156800,
          "model_inventory": [
            { "role": "denoise", "implementation": "DnCNN-color-v1.2", "version": "1.2", "size_bytes": 2400000, "spdx_license": "MIT", "format": "mlpackage" },
            { "role": "denoise", "implementation": "DnCNN-gray-v1.2", "version": "1.2", "size_bytes": 800000, "spdx_license": "MIT", "format": "mlpackage" },
            { "role": "artifact_removal", "implementation": "ARCNN-v1.0", "version": "1.0", "size_bytes": 1100000, "spdx_license": "MIT", "format": "mlpackage" },
            { "role": "super_resolution_2x", "implementation": "ESPCN-2x-v1.0", "version": "1.0", "size_bytes": 240000, "spdx_license": "MIT", "format": "mlpackage" },
            { "role": "super_resolution_4x", "implementation": "ESPCN-4x-v1.0", "version": "1.0", "size_bytes": 380000, "spdx_license": "MIT", "format": "mlpackage" },
            { "role": "quality_regressor", "implementation": "QualityRegressor-CNN-v1.0", "version": "1.0", "size_bytes": 9236800, "spdx_license": "Proprietary", "format": "mlpackage" }
          ],
          "runs": [
            {
              "clip_id": "general-film-01",
              "optimization_level": "balanced",
              "resolution": "1920x1080",
              "frame_count": 731,
              "speed": {
                "ms_per_frame_mean": 28.4, "ms_per_frame_median": 27.9,
                "ms_per_frame_p95": 32.1, "ms_per_frame_p99": 35.0,
                "ms_per_frame_stddev": 2.1, "ms_first_frame": 184.2,
                "realtime_factor": 1.47, "fps_mean": 35.2
              },
              "quality": { "vmaf": 92.4, "psnr_db": 38.2, "ssim": 0.987, "ms_ssim": 0.992, "lpips": 0.024 },
              "memory": { "peak_bytes": 847000000, "steady_state_bytes": 720000000, "model_resident_bytes": 14156800 },
              "compression": {
                "input_bytes": 102400000, "output_bytes": 66560000,
                "ratio_vs_baseline": 0.65, "savings_vs_baseline": 0.35,
                "encoder": "h264_videotoolbox",
                "encoder_settings": { "bitrate_kbps": 3500, "profile": "high", "level": "4.1" }
              },
              "status": "success"
            },
            {
              "clip_id": "signage-static-04",
              "optimization_level": "maximum",
              "resolution": "1920x1080",
              "frame_count": 1800,
              "speed": {
                "ms_per_frame_mean": 67.8, "ms_per_frame_median": 66.2,
                "ms_per_frame_p95": 78.4, "ms_per_frame_p99": 91.0,
                "ms_per_frame_stddev": 5.3, "ms_first_frame": 312.5,
                "realtime_factor": 0.49, "fps_mean": 14.7
              },
              "quality": { "vmaf": 87.2, "psnr_db": 35.9, "ssim": 0.974, "lpips": 0.041 },
              "memory": { "peak_bytes": 1240000000, "steady_state_bytes": 980000000, "model_resident_bytes": 14156800 },
              "compression": {
                "input_bytes": 380000000, "output_bytes": 159600000,
                "ratio_vs_baseline": 0.42, "savings_vs_baseline": 0.58,
                "encoder": "hevc_videotoolbox",
                "encoder_settings": { "bitrate_kbps": 2200, "profile": "main" }
              },
              "status": "success"
            }
          ]
        },
        "forge_upscaler": {
          "bundle_bytes": 67200000,
          "model_inventory": [
            { "role": "playback_upscaler", "implementation": "SRVGGNetCompact-v1.0", "version": "1.0", "size_bytes": 2400000, "spdx_license": "BSD-3-Clause", "format": "mlpackage" },
            { "role": "export_upscaler", "implementation": "RRDBNet-x4plus-v1.0", "version": "1.0", "size_bytes": 64800000, "spdx_license": "BSD-3-Clause", "format": "mlpackage" }
          ],
          "tiers": {
            "playback": [
              {
                "clip_id": "general-film-01",
                "input_resolution": "1920x1080",
                "output_resolution": "3840x2160",
                "scale_factor": 2,
                "frame_count": 731,
                "speed": {
                  "ms_per_frame_mean": 31.2, "ms_per_frame_median": 30.8,
                  "ms_per_frame_p95": 34.5, "ms_per_frame_p99": 38.1,
                  "ms_per_frame_stddev": 1.8, "ms_first_frame": 142.0,
                  "realtime_factor": 1.34, "fps_mean": 32.1
                },
                "quality": { "vmaf": 91.8, "psnr_db": 32.4, "ssim": 0.952, "lpips": 0.058 },
                "memory": { "peak_bytes": 1820000000, "model_resident_bytes": 2400000 },
                "status": "success"
              }
            ],
            "export": [
              {
                "clip_id": "general-film-01",
                "input_resolution": "1920x1080",
                "output_resolution": "3840x2160",
                "scale_factor": 2,
                "frame_count": 731,
                "speed": {
                  "ms_per_frame_mean": 412.0, "ms_per_frame_median": 408.0,
                  "ms_per_frame_p95": 445.0, "ms_per_frame_p99": 478.0,
                  "ms_per_frame_stddev": 14.2, "ms_first_frame": 1820.0,
                  "realtime_factor": 0.10, "fps_mean": 2.4
                },
                "quality": { "vmaf": 95.2, "psnr_db": 34.8, "ssim": 0.971, "lpips": 0.032 },
                "memory": { "peak_bytes": 4200000000, "model_resident_bytes": 64800000 },
                "status": "success"
              }
            ]
          }
        }
      },
      "gates": {
        "version": "v1.0",
        "all_passed": false,
        "results": [
          { "gate_id": "bundle_size_max", "description": "Total .mlpackage bytes in Resources/Models/ (ForgeOptimizer)", "comparison": "lte", "target": 12000000, "actual": 14156800, "passed": false },
          { "gate_id": "throughput_balanced_m4pro_1080p", "description": "Realtime factor at 1080p Balanced on M4 Pro, mean over general subset", "comparison": "gte", "target": 0.7, "actual": 1.47, "passed": true, "hardware_required": "M4 Pro", "corpus_subset": "general" },
          { "gate_id": "vmaf_balanced_min", "description": "VMAF at Balanced, mean over all clips", "comparison": "gte", "target": 90.0, "actual": 92.4, "passed": true, "corpus_subset": "all" },
          { "gate_id": "compression_balanced_min", "description": "Savings vs non-optimized at Balanced, mean over general subset", "comparison": "gte", "target": 0.35, "actual": 0.35, "passed": true, "corpus_subset": "general" },
          { "gate_id": "compression_signage_max_min", "description": "Savings vs non-optimized at Maximum on signage subset", "comparison": "gte", "target": 0.55, "actual": 0.58, "passed": true, "corpus_subset": "signage" },
          { "gate_id": "playback_4k_fps_min", "description": "Playback tier fps at 1080p→4K on M4 Pro", "comparison": "gte", "target": 30.0, "actual": 32.1, "passed": true, "hardware_required": "M4 Pro" },
          { "gate_id": "quality_regressor_srcc_min", "description": "SRCC vs human MOS on signage holdout (only valid after Phase E)", "comparison": "gte", "target": 0.90, "actual": 0.0, "passed": false, "tolerance": 1.0 }
        ]
      }
    }
    """#
}
