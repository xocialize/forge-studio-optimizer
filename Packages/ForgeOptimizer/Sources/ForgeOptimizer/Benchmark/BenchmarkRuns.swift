//
// BenchmarkRuns.swift
// ForgeOptimizer / Benchmark
//
// Per-clip run records for ForgeOptimizer and ForgeUpscaler pipelines,
// plus the shared `RunStatus` enum. Verbatim Codable from the schema
// document §4.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import Foundation

public struct OptimizerRun: Codable, Sendable {
    public let clipID: String
    public let optimizationLevel: OptimizationLevel
    public let resolution: String
    public let frameCount: Int?
    public let speed: SpeedMetrics?
    public let quality: QualityMetrics?
    public let memory: MemoryMetrics?
    public let compression: CompressionMetrics?
    public let status: RunStatus
    public let failureReason: String?

    public enum OptimizationLevel: String, Codable, Sendable {
        case off, light, balanced, aggressive, maximum
    }

    public init(
        clipID: String,
        optimizationLevel: OptimizationLevel,
        resolution: String,
        frameCount: Int? = nil,
        speed: SpeedMetrics? = nil,
        quality: QualityMetrics? = nil,
        memory: MemoryMetrics? = nil,
        compression: CompressionMetrics? = nil,
        status: RunStatus,
        failureReason: String? = nil
    ) {
        self.clipID = clipID
        self.optimizationLevel = optimizationLevel
        self.resolution = resolution
        self.frameCount = frameCount
        self.speed = speed
        self.quality = quality
        self.memory = memory
        self.compression = compression
        self.status = status
        self.failureReason = failureReason
    }

    enum CodingKeys: String, CodingKey {
        case clipID = "clip_id"
        case optimizationLevel = "optimization_level"
        case resolution
        case frameCount = "frame_count"
        case speed, quality, memory, compression, status
        case failureReason = "failure_reason"
    }
}

public struct UpscalerRun: Codable, Sendable {
    public let clipID: String
    public let inputResolution: String
    public let outputResolution: String
    public let scaleFactor: Int?
    public let frameCount: Int?
    public let speed: SpeedMetrics?
    public let quality: QualityMetrics?
    public let memory: MemoryMetrics?
    public let textMetrics: TextMetrics?
    public let status: RunStatus
    public let failureReason: String?

    /// Identifier of the playback backend that produced the run, e.g.
    /// `"efrlfn-x4"`, `"srvggnet-general-x4"`. Sourced from
    /// `PlaybackTier.name`. Optional — Phase A.2-vintage records emitted
    /// before the C.4 A/B don't carry this field, and only the playback
    /// tier currently populates it. Export / signage tiers leave it `nil`.
    /// The schema's `UpscalerRun` def is open on `additionalProperties`
    /// (per Forge-BenchmarkSchema-v1.0.md §4 "nested structures are
    /// open"), so adding the field is backward-compatible.
    public let backend: String?

    public init(
        clipID: String,
        inputResolution: String,
        outputResolution: String,
        scaleFactor: Int? = nil,
        frameCount: Int? = nil,
        speed: SpeedMetrics? = nil,
        quality: QualityMetrics? = nil,
        memory: MemoryMetrics? = nil,
        textMetrics: TextMetrics? = nil,
        status: RunStatus,
        failureReason: String? = nil,
        backend: String? = nil
    ) {
        self.clipID = clipID
        self.inputResolution = inputResolution
        self.outputResolution = outputResolution
        self.scaleFactor = scaleFactor
        self.frameCount = frameCount
        self.speed = speed
        self.quality = quality
        self.memory = memory
        self.textMetrics = textMetrics
        self.status = status
        self.failureReason = failureReason
        self.backend = backend
    }

    enum CodingKeys: String, CodingKey {
        case clipID = "clip_id"
        case inputResolution = "input_resolution"
        case outputResolution = "output_resolution"
        case scaleFactor = "scale_factor"
        case frameCount = "frame_count"
        case speed, quality, memory
        case textMetrics = "text_metrics"
        case status
        case failureReason = "failure_reason"
        case backend
    }
}

public enum RunStatus: String, Codable, Sendable {
    case success, partial, failed
}
