//
// ModelRole.swift
// ForgeOptimizer / ModelRegistry
//
// Canonical role enum for every model vendored into ForgeOptimizer.
//
// Raw values are snake_case to match the JSON shape of
// `ModelInventoryEntry.role` in the Forge benchmark schema (§4). This
// means `ModelRegistry.inventory()` can be encoded directly into a
// benchmark report without an intermediate transform.
//
// Per Forge 2026 Q2 refresh plan §A.3. The role set covers v0.3 baseline
// (restoration / denoise / artifactRemoval / superResolution2x|4x /
// qualityRegressor) plus the post-Phase-A roles the registry will need to
// hold (saliency, guidedFilter, playbackUpscaler, exportUpscaler,
// signageUpscaler, opticalFlow). Adding a role here does *not* register a
// model — manifests are still registered explicitly on the actor.
//

import Foundation

/// Functional role a model plays in the Forge AI pipeline.
public enum ModelRole: String, Sendable, Codable, CaseIterable, Hashable {
    case restoration = "restoration"
    case denoise = "denoise"
    case artifactRemoval = "artifact_removal"
    case superResolution2x = "super_resolution_2x"
    case superResolution4x = "super_resolution_4x"
    case saliency = "saliency"
    case qualityRegressor = "quality_regressor"
    case guidedFilter = "guided_filter"
    case playbackUpscaler = "playback_upscaler"
    case exportUpscaler = "export_upscaler"
    case signageUpscaler = "signage_upscaler"
    case opticalFlow = "optical_flow"
}
