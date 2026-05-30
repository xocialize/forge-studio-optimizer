//
// ModelManifest.swift
// ForgeOptimizer / ModelRegistry
//
// Declarative description of a single bundled model.
//
// Mirrors `ModelInventoryEntry` from the Forge benchmark schema (§4) so
// `ModelRegistry.inventory()` can be emitted into the benchmark report
// directly. Codable field names use snake_case to match the JSON shape.
//
// Per Forge 2026 Q2 refresh plan §A.3.
//

import Foundation

/// Manifest entry for a single bundled CoreML model.
///
/// A manifest declares *where* the model lives in the SwiftPM resource
/// bundle and *what* license its weights ship under. `ModelRegistry`
/// consumes manifests; it never reads the underlying `.mlpackage` until
/// the first request for that role + implementation pair.
public struct ModelManifest: Sendable, Codable, Hashable {

    /// Functional role this model serves in the pipeline.
    public let role: ModelRole

    /// Implementation identifier, used to disambiguate A/B variants under
    /// the same role (e.g. `"dncnn_color"` vs a future `"nafnet_color"`).
    public let implementation: String

    /// Semantic-ish version string (free-form). Surfaces in benchmark
    /// reports.
    public let version: String

    /// SPDX identifier for the *weights*, not the framework. Enforced
    /// at load time by the active `LicensePolicy`.
    public let weightLicense: SPDXLicense

    /// Filename (without extension) inside `Bundle.module`'s resource root.
    public let bundleResourceName: String

    /// File extension. Defaults to `"mlpackage"`.
    public let bundleResourceExtension: String

    /// Spatial input size, if the model is a fixed-size image processor.
    /// `nil` for scalar regressors that take arbitrary input.
    public let inputSize: Int?

    /// Free-form notes (e.g. "Phase A.3 baseline; replace in Phase B").
    public let notes: String?

    public init(
        role: ModelRole,
        implementation: String,
        version: String,
        weightLicense: SPDXLicense,
        bundleResourceName: String,
        bundleResourceExtension: String = "mlpackage",
        inputSize: Int? = nil,
        notes: String? = nil
    ) {
        self.role = role
        self.implementation = implementation
        self.version = version
        self.weightLicense = weightLicense
        self.bundleResourceName = bundleResourceName
        self.bundleResourceExtension = bundleResourceExtension
        self.inputSize = inputSize
        self.notes = notes
    }

    // snake_case JSON keys to match ModelInventoryEntry.
    private enum CodingKeys: String, CodingKey {
        case role
        case implementation
        case version
        case weightLicense = "weight_license"
        case bundleResourceName = "bundle_resource_name"
        case bundleResourceExtension = "bundle_resource_extension"
        case inputSize = "input_size"
        case notes
    }
}
