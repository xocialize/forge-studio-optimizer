//
// PipelineResults.swift
// ForgeOptimizer / Benchmark
//
// `pipeline_results` top-level object plus its sub-shapes for the
// ForgeOptimizer and ForgeUpscaler pipelines. Verbatim Codable from the
// schema document §4.
//
// `ModelInventoryEntry` mirrors `ModelManifest` in the registry but
// expresses it in the benchmark report's role + SPDX language — it is
// the on-disk shape, not the in-memory manifest. `InventoryEnumerator`
// translates registry manifests into these entries.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import Foundation

public struct PipelineResults: Codable, Sendable {
    public let forgeOptimizer: ForgeOptimizerResults?
    public let forgeUpscaler: ForgeUpscalerResults?

    public init(
        forgeOptimizer: ForgeOptimizerResults? = nil,
        forgeUpscaler: ForgeUpscalerResults? = nil
    ) {
        self.forgeOptimizer = forgeOptimizer
        self.forgeUpscaler = forgeUpscaler
    }

    enum CodingKeys: String, CodingKey {
        case forgeOptimizer = "forge_optimizer"
        case forgeUpscaler = "forge_upscaler"
    }
}

public struct ForgeOptimizerResults: Codable, Sendable {
    public let bundleBytes: Int
    public let modelInventory: [ModelInventoryEntry]
    public let runs: [OptimizerRun]

    public init(
        bundleBytes: Int,
        modelInventory: [ModelInventoryEntry],
        runs: [OptimizerRun]
    ) {
        self.bundleBytes = bundleBytes
        self.modelInventory = modelInventory
        self.runs = runs
    }

    enum CodingKeys: String, CodingKey {
        case bundleBytes = "bundle_bytes"
        case modelInventory = "model_inventory"
        case runs
    }
}

public struct ForgeUpscalerResults: Codable, Sendable {
    public let bundleBytes: Int
    public let modelInventory: [ModelInventoryEntry]
    public let tiers: Tiers

    public struct Tiers: Codable, Sendable {
        public let playback: [UpscalerRun]?
        public let export: [UpscalerRun]?
        public let signage: [UpscalerRun]?

        public init(
            playback: [UpscalerRun]? = nil,
            export: [UpscalerRun]? = nil,
            signage: [UpscalerRun]? = nil
        ) {
            self.playback = playback
            self.export = export
            self.signage = signage
        }
    }

    public init(
        bundleBytes: Int,
        modelInventory: [ModelInventoryEntry],
        tiers: Tiers
    ) {
        self.bundleBytes = bundleBytes
        self.modelInventory = modelInventory
        self.tiers = tiers
    }

    enum CodingKeys: String, CodingKey {
        case bundleBytes = "bundle_bytes"
        case modelInventory = "model_inventory"
        case tiers
    }
}

public struct ModelInventoryEntry: Codable, Sendable {
    public let role: ModelRole
    public let implementation: String
    public let version: String?
    public let sizeBytes: Int
    public let spdxLicense: String
    public let format: ModelFormat?

    public enum ModelRole: String, Codable, Sendable {
        case restoration, denoise
        case artifactRemoval = "artifact_removal"
        case superResolution2x = "super_resolution_2x"
        case superResolution4x = "super_resolution_4x"
        case saliency
        case qualityRegressor = "quality_regressor"
        case guidedFilter = "guided_filter"
        case playbackUpscaler = "playback_upscaler"
        case exportUpscaler = "export_upscaler"
        case signageUpscaler = "signage_upscaler"
        case opticalFlow = "optical_flow"
    }

    public enum ModelFormat: String, Codable, Sendable {
        case mlpackage, safetensors, mlmodelc
    }

    public init(
        role: ModelRole,
        implementation: String,
        version: String? = nil,
        sizeBytes: Int,
        spdxLicense: String,
        format: ModelFormat? = nil
    ) {
        self.role = role
        self.implementation = implementation
        self.version = version
        self.sizeBytes = sizeBytes
        self.spdxLicense = spdxLicense
        self.format = format
    }

    enum CodingKeys: String, CodingKey {
        case role, implementation, version
        case sizeBytes = "size_bytes"
        case spdxLicense = "spdx_license"
        case format
    }
}
