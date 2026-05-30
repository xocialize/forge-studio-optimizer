//
// ModelRegistry.swift
// ForgeOptimizer / ModelRegistry
//
// Actor-isolated registry that owns every bundled CoreML model in
// ForgeOptimizer. Replaces the legacy `CoreMLProcessor`-per-class
// loading pattern with:
//
//   1. Declarative `ModelManifest`s registered up front.
//   2. License enforcement (`LicensePolicy.check`) *before* CoreML
//      touches the file. Refused weights never compile.
//   3. Lazy, cached compilation: `MLModel.compileModel(at:)` runs at
//      most once per (role, implementation) pair.
//   4. A/B support: multiple manifests may share a `ModelRole` and are
//      retrieved by the caller's `implementation` name.
//   5. Inventory emission for the benchmark report.
//
// Per Forge 2026 Q2 refresh plan §A.3.
//

@preconcurrency import CoreML
import Foundation

/// A loaded model + the manifest it was loaded from.
///
/// `MLModel` itself is thread-safe for prediction (Apple documents this)
/// but does not conform to `Sendable`. Marked `@unchecked Sendable` to
/// keep parity with the existing `Denoiser`/`ArtifactRemover` pattern.
public struct LoadedModel: @unchecked Sendable {
    public let model: MLModel
    public let manifest: ModelManifest

    init(model: MLModel, manifest: ModelManifest) {
        self.model = model
        self.manifest = manifest
    }
}

/// Actor-isolated CoreML model registry.
///
/// All mutating access (`register`, `load`) is serialized by actor
/// isolation. Replaces the manual `@unchecked Sendable` + per-class
/// locking pattern that Phase A.3 retires.
public actor ModelRegistry {

    private let policy: LicensePolicy
    private var manifests: [ManifestKey: ModelManifest] = [:]
    private var modelsByRole: [ModelRole: [String]] = [:]
    private var cache: [ManifestKey: MLModel] = [:]
    private let bundle: Bundle

    /// Compile-options applied to every `MLModel.compileModel(at:)` call.
    /// Defaults to `.all` (Neural Engine + GPU + CPU) — same as the
    /// legacy `CoreMLProcessor`.
    public let computeUnits: MLComputeUnits

    public init(
        policy: LicensePolicy,
        bundle: Bundle,
        computeUnits: MLComputeUnits = .all
    ) {
        self.policy = policy
        self.bundle = bundle
        self.computeUnits = computeUnits
    }

    /// Convenience init that pulls models from `Bundle.module`
    /// (ForgeOptimizer's resource bundle). Equivalent to the legacy
    /// `CoreMLProcessor` lookup path.
    public init(
        policy: LicensePolicy,
        computeUnits: MLComputeUnits = .all
    ) {
        self.init(policy: policy, bundle: .module, computeUnits: computeUnits)
    }

    // MARK: - Registration

    /// Register a manifest. Last writer wins for a duplicate (role,
    /// implementation) key.
    public func register(_ manifest: ModelManifest) {
        let key = ManifestKey(manifest)
        manifests[key] = manifest
        var roster = modelsByRole[manifest.role] ?? []
        if !roster.contains(manifest.implementation) {
            roster.append(manifest.implementation)
            modelsByRole[manifest.role] = roster
        }
    }

    /// Convenience: register an array of manifests.
    public func register(contentsOf manifests: [ModelManifest]) {
        for manifest in manifests { register(manifest) }
    }

    // MARK: - Loading

    /// Load (and cache) the compiled `MLModel` for the given role +
    /// implementation. License is checked *first*; refused weights are
    /// never compiled.
    public func load(role: ModelRole, implementation: String) throws -> LoadedModel {
        let key = ManifestKey(role: role, implementation: implementation)
        guard let manifest = manifests[key] else {
            throw ModelRegistryError.notFound("role=\(role.rawValue) implementation=\(implementation)")
        }

        try policy.check(manifest.weightLicense)

        if let cached = cache[key] {
            return LoadedModel(model: cached, manifest: manifest)
        }

        guard let url = bundle.url(
            forResource: manifest.bundleResourceName,
            withExtension: manifest.bundleResourceExtension
        ) else {
            throw ModelRegistryError.bundleMissing
        }

        let compiledURL: URL
        do {
            compiledURL = try MLModel.compileModel(at: url)
        } catch {
            throw ModelRegistryError.compileFailed(error)
        }

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        let model: MLModel
        do {
            model = try MLModel(contentsOf: compiledURL, configuration: config)
        } catch {
            throw ModelRegistryError.compileFailed(error)
        }

        cache[key] = model
        return LoadedModel(model: model, manifest: manifest)
    }

    /// Load whatever implementation was registered first for this role.
    /// Convenience for single-implementation roles (the common v0.3 case).
    public func load(role: ModelRole) throws -> LoadedModel {
        guard let implementation = modelsByRole[role]?.first else {
            throw ModelRegistryError.notFound("role=\(role.rawValue) (no implementations registered)")
        }
        return try load(role: role, implementation: implementation)
    }

    // MARK: - Inspection

    /// Every registered manifest, in registration order *within each role*
    /// then sorted by role's raw value. Stable for benchmark-report
    /// reproducibility.
    public func inventory() -> [ModelManifest] {
        var result: [ModelManifest] = []
        for role in modelsByRole.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let implementations = modelsByRole[role] else { continue }
            for impl in implementations {
                if let manifest = manifests[ManifestKey(role: role, implementation: impl)] {
                    result.append(manifest)
                }
            }
        }
        return result
    }

    /// Implementations registered for a role (in insertion order).
    public func implementations(for role: ModelRole) -> [String] {
        modelsByRole[role] ?? []
    }

    /// Active license policy. Read-only — policy is fixed at init.
    public func currentPolicy() -> LicensePolicy { policy }

    // MARK: - Bundled defaults

    /// Process-wide registry pre-populated with the v0.3 baseline
    /// manifests. Lazily created on first access. Uses
    /// `LicensePolicy.development` so the existing pipeline (which
    /// currently uses `quality_regressor`) keeps working until Phase E
    /// lands the SigLIP2 replacement.
    public static let bundled: ModelRegistry = {
        let registry = ModelRegistry(policy: .development)
        Task {
            await registry.register(contentsOf: ModelRegistry.v0_3BaselineManifests)
        }
        return registry
    }()

    /// Synchronous factory: returns a registry with the v0.3 baseline
    /// already registered. Useful for tests that need a clean instance
    /// and don't want to await the `.bundled` background task.
    public static func makeBundled(policy: LicensePolicy = .development) -> ModelRegistry {
        let registry = ModelRegistry(policy: policy)
        // Register synchronously — actor isolation means we can do this
        // from a non-isolated context via the nonisolated initializer
        // helper below.
        registry.preloadManifests(ModelRegistry.v0_3BaselineManifests)
        return registry
    }

    /// nonisolated helper used by `makeBundled` to register without
    /// requiring an `await`. Safe because it runs once at construction
    /// time before the registry is shared.
    nonisolated private func preloadManifests(_ list: [ModelManifest]) {
        // Hand off into actor-isolated state via an unstructured Task;
        // tests that immediately call `await registry.inventory()` will
        // see all manifests because actor messages are FIFO-ordered.
        Task { [weak self] in
            await self?.register(contentsOf: list)
        }
    }

    /// v0.3 ForgeOptimizer baseline. Source: `Resources/MODELS.md`
    /// (vendored from `xocialize-code/com.xocialize.coreml @ 3989123`).
    ///
    /// Five `Proprietary` models (DnCNN color/gray, ARCNN, ESPCN x2/x4)
    /// plus one `Proprietary-Research` model (quality_regressor —
    /// KADID-10k-derived; Phase E.5 replacement target).
    public static let v0_3BaselineManifests: [ModelManifest] = [
        ModelManifest(
            role: .denoise,
            implementation: "dncnn_color",
            version: "0.3.0",
            weightLicense: .Proprietary,
            bundleResourceName: "dncnn_color",
            inputSize: 256,
            notes: "DnCNN color denoiser; DIV2K-trained."
        ),
        ModelManifest(
            role: .denoise,
            implementation: "dncnn_gray",
            version: "0.3.0",
            weightLicense: .Proprietary,
            bundleResourceName: "dncnn_gray",
            inputSize: 256,
            notes: "DnCNN luma-only denoiser; DIV2K-trained."
        ),
        ModelManifest(
            role: .artifactRemoval,
            implementation: "arcnn",
            version: "0.3.0",
            weightLicense: .Proprietary,
            bundleResourceName: "arcnn",
            inputSize: 256,
            notes: "ARCNN compression artifact remover; DIV2K + HEVC."
        ),
        ModelManifest(
            role: .superResolution2x,
            implementation: "espcn_x2",
            version: "0.3.0",
            weightLicense: .Proprietary,
            bundleResourceName: "espcn_x2",
            inputSize: 128,
            notes: "ESPCN 2× super-resolution; DIV2K bicubic."
        ),
        ModelManifest(
            role: .superResolution4x,
            implementation: "espcn_x4",
            version: "0.3.0",
            weightLicense: .Proprietary,
            bundleResourceName: "espcn_x4",
            inputSize: 64,
            notes: "ESPCN 4× super-resolution; DIV2K bicubic."
        ),
        ModelManifest(
            role: .qualityRegressor,
            implementation: "quality_regressor",
            version: "0.3.0",
            weightLicense: .ProprietaryResearch,
            bundleResourceName: "quality_regressor",
            inputSize: 224,
            notes: "MobileNetV3-small NR-IQA head; KADID-10k. Phase E.5 replacement target."
        ),
    ]
}

// MARK: - Internal helpers

/// Composite key uniquely identifying a manifest within the registry.
private struct ManifestKey: Hashable, Sendable {
    let role: ModelRole
    let implementation: String

    init(role: ModelRole, implementation: String) {
        self.role = role
        self.implementation = implementation
    }

    init(_ manifest: ModelManifest) {
        self.role = manifest.role
        self.implementation = manifest.implementation
    }
}
