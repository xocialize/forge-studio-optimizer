//
// SPDXLicense.swift
// ForgeOptimizer / ModelRegistry
//
// Typed SPDX identifier for weights vendored into ForgeOptimizer.
//
// Per Forge 2026 Q2 refresh plan §A.3 every bundled model carries a
// `weightLicense: SPDXLicense` field that the `LicensePolicy` consults at
// load time. The enum intentionally distinguishes *commercial-OK* SPDX
// identifiers from `Proprietary-Research`, which covers weights trained on
// research-only corpora (e.g. KADID-10k) where the derivative status is
// legally murky and the model must be gated out of commercial builds.
//

import Foundation

/// Typed SPDX license identifier.
///
/// Raw values are canonical SPDX strings so they round-trip cleanly into
/// the benchmark report's `ModelInventoryEntry.weight_license` field.
public enum SPDXLicense: String, Sendable, Codable, CaseIterable, Hashable {
    case MIT = "MIT"
    case Apache2 = "Apache-2.0"
    case BSD3Clause = "BSD-3-Clause"
    case BSD2Clause = "BSD-2-Clause"
    case CCBy4 = "CC-BY-4.0"
    case Proprietary = "Proprietary"
    /// Non-commercial: weights derived from a research-only corpus
    /// (e.g. KADID-10k). Allowed in `.development` policy only.
    case ProprietaryResearch = "Proprietary-Research"

    /// Whether this license permits unrestricted commercial use of the weights.
    ///
    /// `Proprietary` is commercial-OK because MVS Collective owns the
    /// trained weights outright. `Proprietary-Research` is *not* because
    /// the upstream corpus prohibits commercial derivatives.
    public var commercialUseAllowed: Bool {
        switch self {
        case .MIT, .Apache2, .BSD3Clause, .BSD2Clause, .CCBy4, .Proprietary:
            return true
        case .ProprietaryResearch:
            return false
        }
    }
}
