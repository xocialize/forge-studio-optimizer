//
// InventoryEnumerator.swift
// ForgeOptimizer / Benchmark
//
// Translates the in-memory `ModelManifest` set from `ModelRegistry`
// into the on-disk `ModelInventoryEntry` shape the benchmark report
// expects. The two structs intentionally share their `role` raw
// values so the conversion is a straight field copy + a license enum
// → SPDX string + a bundle file-size lookup.
//
// Per Forge 2026 Q2 refresh plan §A.2 / Phase A.3 inventory hook.
//

import Foundation

public struct InventoryEnumerator: Sendable {

    /// Resource bundle in which the registry's `.mlpackage` files
    /// live. The benchmark suite for `ForgeUpscaler` will pass that
    /// package's bundle.
    public let bundle: Bundle

    public init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// Convenience: build an enumerator backed by ForgeOptimizer's own
    /// `Bundle.module`. Used by `BenchmarkSuite` for the
    /// `forge_optimizer` results block.
    public static func forgeOptimizerBundle() -> InventoryEnumerator {
        InventoryEnumerator(bundle: .module)
    }

    /// Enumerate `manifests` into `ModelInventoryEntry` records. The
    /// total `bundle_bytes` for a results block is `entries.map(\.sizeBytes).reduce(0, +)`.
    public func enumerate(manifests: [ModelManifest]) -> [ModelInventoryEntry] {
        manifests.map { manifest in
            let size = bundleSizeBytes(
                resourceName: manifest.bundleResourceName,
                resourceExtension: manifest.bundleResourceExtension
            )
            return ModelInventoryEntry(
                role: Self.translateRole(manifest.role),
                implementation: manifest.implementation,
                version: manifest.version,
                sizeBytes: size,
                spdxLicense: manifest.weightLicense.rawValue,
                format: Self.translateFormat(manifest.bundleResourceExtension)
            )
        }
    }

    /// Resolve a registry-side `ModelRole` to the schema's
    /// `ModelInventoryEntry.ModelRole`. The raw values are intentionally
    /// the same on both sides (see `ModelRole.swift` + the schema §4
    /// enum); if anyone diverges, this is the chokepoint that catches
    /// it.
    static func translateRole(_ role: ModelRole) -> ModelInventoryEntry.ModelRole {
        // ModelInventoryEntry.ModelRole and ModelRole share raw values
        // by design — bridge via rawValue and crash loudly if a new
        // role ever ships without a matching report-side enum case.
        guard let translated = ModelInventoryEntry.ModelRole(rawValue: role.rawValue) else {
            preconditionFailure("ModelInventoryEntry.ModelRole missing case for \(role.rawValue) — schema and registry drifted")
        }
        return translated
    }

    /// Map a bundle file extension to the schema's `ModelFormat` enum.
    /// Unknown extensions return nil — the field is optional.
    static func translateFormat(_ ext: String) -> ModelInventoryEntry.ModelFormat? {
        ModelInventoryEntry.ModelFormat(rawValue: ext.lowercased())
    }

    /// Total bytes consumed by a bundled resource (sums a directory if
    /// the resource is a `.mlpackage` bundle, falls back to single file
    /// size otherwise). Returns 0 when the resource isn't present —
    /// matches the schema's `minimum: 0` constraint.
    func bundleSizeBytes(resourceName: String, resourceExtension: String) -> Int {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            return 0
        }
        return Self.recursiveSize(at: url)
    }

    /// Walk a URL recursively, summing regular-file sizes.
    static func recursiveSize(at url: URL) -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return 0
        }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            if let size = (attrs?[.size] as? NSNumber)?.intValue {
                return size
            }
            return 0
        }
        // Directory: enumerate.
        var total = 0
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }
            if values.isRegularFile == true, let size = values.fileSize {
                total += size
            }
        }
        return total
    }
}
