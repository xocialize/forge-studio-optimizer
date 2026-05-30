//
// LicensePolicy.swift
// ForgeOptimizer / ModelRegistry
//
// Allow-list governing which SPDX-tagged weights ModelRegistry will load.
//
// Two canonical policies ship out-of-the-box:
//   - `.commercial` — strips Proprietary-Research (so KADID-10k-derived
//     quality_regressor is refused before MLX/CoreML even sees the file).
//   - `.development` — every known SPDX identifier is allowed.
//
// Per Forge 2026 Q2 refresh plan §A.3. Pattern modeled after the DubKit
// LicensePolicy reference cited in the plan.
//

import Foundation

/// Allow-list of `SPDXLicense` values that the registry may load.
public struct LicensePolicy: Sendable, Hashable {

    /// Distinguishes a commercial app build from an internal/eval build.
    /// Carried separately so error messages can report *why* a load was
    /// refused without leaking the full allowed-set.
    public enum Mode: String, Sendable, Codable, Hashable {
        case commercial
        case development
    }

    public let mode: Mode
    public let allowedLicenses: Set<SPDXLicense>

    public init(mode: Mode, allowedLicenses: Set<SPDXLicense>) {
        self.mode = mode
        self.allowedLicenses = allowedLicenses
    }

    /// Allow everything whose `commercialUseAllowed` is `true`.
    /// Refuses `Proprietary-Research`.
    public static let commercial = LicensePolicy(
        mode: .commercial,
        allowedLicenses: Set(SPDXLicense.allCases.filter { $0.commercialUseAllowed })
    )

    /// Allow every known SPDX identifier. Use for benchmarking and
    /// internal evaluation only; never ship.
    public static let development = LicensePolicy(
        mode: .development,
        allowedLicenses: Set(SPDXLicense.allCases)
    )

    /// Throws `ModelRegistryError.licenseRefused` if `license` is not in
    /// `allowedLicenses`. The error carries the policy mode so callers
    /// can surface a useful diagnostic.
    public func check(_ license: SPDXLicense) throws {
        guard allowedLicenses.contains(license) else {
            throw ModelRegistryError.licenseRefused(license, mode)
        }
    }
}
