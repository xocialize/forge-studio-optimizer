//
// BenchmarkReport.swift
// ForgeOptimizer / Benchmark
//
// Top-level Codable shape for a single benchmark run. The schema is
// authoritative in `Docs/Forge-BenchmarkSchema-v1.0.md §2 / §4`; this
// file (and its siblings under `Benchmark/`) is the verbatim Swift
// drop-in from §4 of that document.
//
// `BenchmarkReport` is the entire on-disk payload. `BenchmarkSuite`
// emits one of these per run via a pretty-printed `JSONEncoder` with
// `.sortedKeys` + ISO-8601 timestamps; CI's gate-checker (per schema
// §6) deserializes it back and inspects `gates.results[].passed`.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import Foundation

// MARK: - Top-level report

public struct BenchmarkReport: Codable, Sendable {
    public let schemaVersion: String
    public let reportID: UUID
    public let timestampUTC: Date
    public let runLabel: String
    public let notes: String?
    public let git: GitInfo
    public let hardware: HardwareInfo
    public let dependencies: Dependencies
    public let corpus: Corpus
    public let pipelineResults: PipelineResults
    public let gates: GateEvaluation

    public init(
        schemaVersion: String = "1.0",
        reportID: UUID = UUID(),
        timestampUTC: Date = Date(),
        runLabel: String,
        notes: String? = nil,
        git: GitInfo,
        hardware: HardwareInfo,
        dependencies: Dependencies,
        corpus: Corpus,
        pipelineResults: PipelineResults,
        gates: GateEvaluation
    ) {
        self.schemaVersion = schemaVersion
        self.reportID = reportID
        self.timestampUTC = timestampUTC
        self.runLabel = runLabel
        self.notes = notes
        self.git = git
        self.hardware = hardware
        self.dependencies = dependencies
        self.corpus = corpus
        self.pipelineResults = pipelineResults
        self.gates = gates
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reportID = "report_id"
        case timestampUTC = "timestamp_utc"
        case runLabel = "run_label"
        case notes, git, hardware, dependencies, corpus
        case pipelineResults = "pipeline_results"
        case gates
    }
}

// MARK: - Provenance

public struct GitInfo: Codable, Sendable {
    public let sha: String
    public let branch: String
    public let dirty: Bool
    public let remoteURL: URL?

    public init(sha: String, branch: String, dirty: Bool, remoteURL: URL? = nil) {
        self.sha = sha
        self.branch = branch
        self.dirty = dirty
        self.remoteURL = remoteURL
    }

    enum CodingKeys: String, CodingKey {
        case sha, branch, dirty
        case remoteURL = "remote_url"
    }
}

public struct HardwareInfo: Codable, Sendable {
    public let modelIdentifier: String
    public let chip: String
    public let cpuCores: Int?
    public let gpuCores: Int?
    public let memoryGB: Double
    public let osVersion: String
    public let thermalState: ThermalState
    public let onBattery: Bool

    public enum ThermalState: String, Codable, Sendable {
        case nominal, fair, serious, critical
    }

    public init(
        modelIdentifier: String,
        chip: String,
        cpuCores: Int?,
        gpuCores: Int?,
        memoryGB: Double,
        osVersion: String,
        thermalState: ThermalState,
        onBattery: Bool
    ) {
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.cpuCores = cpuCores
        self.gpuCores = gpuCores
        self.memoryGB = memoryGB
        self.osVersion = osVersion
        self.thermalState = thermalState
        self.onBattery = onBattery
    }

    enum CodingKeys: String, CodingKey {
        case modelIdentifier = "model_identifier"
        case chip
        case cpuCores = "cpu_cores"
        case gpuCores = "gpu_cores"
        case memoryGB = "memory_gb"
        case osVersion = "os_version"
        case thermalState = "thermal_state"
        case onBattery = "on_battery"
    }
}

public struct Dependencies: Codable, Sendable {
    public let mlxVersion: String
    public let mlxSwiftVersion: String
    public let swiftVersion: String
    public let xcodeVersion: String?
    public let ffmpegVersion: String?
    public let coremlRuntime: String?

    public init(
        mlxVersion: String,
        mlxSwiftVersion: String,
        swiftVersion: String,
        xcodeVersion: String? = nil,
        ffmpegVersion: String? = nil,
        coremlRuntime: String? = nil
    ) {
        self.mlxVersion = mlxVersion
        self.mlxSwiftVersion = mlxSwiftVersion
        self.swiftVersion = swiftVersion
        self.xcodeVersion = xcodeVersion
        self.ffmpegVersion = ffmpegVersion
        self.coremlRuntime = coremlRuntime
    }

    enum CodingKeys: String, CodingKey {
        case mlxVersion = "mlx_version"
        case mlxSwiftVersion = "mlx_swift_version"
        case swiftVersion = "swift_version"
        case xcodeVersion = "xcode_version"
        case ffmpegVersion = "ffmpeg_version"
        case coremlRuntime = "coreml_runtime"
    }
}
