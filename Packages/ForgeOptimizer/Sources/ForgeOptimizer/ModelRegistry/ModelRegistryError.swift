//
// ModelRegistryError.swift
// ForgeOptimizer / ModelRegistry
//
// Error enum shared by `ModelRegistry` and `LicensePolicy`.
//
// Lives in its own file so `LicensePolicy.check` can be added in a
// pre-`ModelRegistry` commit without forward-referencing the actor.
//
// Per Forge 2026 Q2 refresh plan §A.3.
//

import Foundation

/// Errors emitted by `ModelRegistry`.
public enum ModelRegistryError: Error, CustomStringConvertible, Sendable {
    /// `LicensePolicy.check` refused the manifest's weight license.
    case licenseRefused(SPDXLicense, LicensePolicy.Mode)
    /// No manifest matched the requested implementation / role.
    case notFound(String)
    /// The `.mlpackage` was declared in a manifest but not present in
    /// `Bundle.module`. Indicates a packaging mistake, not a license
    /// problem.
    case bundleMissing
    /// CoreML refused to compile the package. Wraps the underlying error.
    case compileFailed(Error)

    public var description: String {
        switch self {
        case let .licenseRefused(license, mode):
            return "Refused to load weights with license \(license.rawValue) under \(mode.rawValue) policy"
        case let .notFound(detail):
            return "Model not found: \(detail)"
        case .bundleMissing:
            return "Model package missing from Bundle.module"
        case let .compileFailed(error):
            return "CoreML compileModel failed: \(error)"
        }
    }
}
