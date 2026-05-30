import Foundation
import Testing
@testable import ForgeOptimizer

/// Smoke tests for the vendored v0.3 baseline `.mlpackage` files.
///
/// These verify that `Bundle.module.url(forResource:withExtension:)` resolves
/// each model name the legacy ForgeOptimizer code path expects. They are pure
/// file-lookup tests — they do NOT load CoreML models (that requires Metal +
/// Xcode runtime per the CLAUDE.md note) and they do NOT touch MLX.
///
/// If any of these fail after a Phase 0.D vendor update, the resource bundle
/// is broken or a model was renamed. Either is loud.
@Suite("Resource bundle — v0.3 baseline mlpackages")
struct ResourceBundleTests {

    /// Names that legacy Restoration/Legacy/* and QualityRegressor/Legacy/* expect.
    /// Single source of truth — update here when adding/removing bundled models.
    static let expectedModels: [String] = [
        "dncnn_color",
        "dncnn_gray",
        "arcnn",
        "espcn_x2",
        "espcn_x4",
        "quality_regressor",
    ]

    @Test("All v0.3 baseline mlpackages resolve in the resource bundle",
          arguments: Self.expectedModels)
    func resolves(_ modelName: String) {
        let url = Bundle.module.url(forResource: modelName, withExtension: "mlpackage")
        #expect(url != nil, "Bundle.module did not return a URL for \(modelName).mlpackage")
        if let url {
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "Resolved URL does not point to an existing file: \(url.path)")
        }
    }

    @Test("MODELS.md is bundled for in-app provenance lookup")
    func modelsDocBundled() {
        let url = Bundle.module.url(forResource: "MODELS", withExtension: "md")
        #expect(url != nil)
    }
}
