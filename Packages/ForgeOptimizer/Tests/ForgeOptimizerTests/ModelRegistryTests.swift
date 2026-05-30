//
// ModelRegistryTests.swift
// ForgeOptimizer / ModelRegistry
//
// Tests for the Phase A.3 ModelRegistry actor + LicensePolicy.
//
// NOTE on `swift test` vs Xcode: actual `MLModel.compileModel(at:)`
// requires the .mlpackage files to be present in `Bundle.module`. The
// worktree's lineage predates the mlpackage vendoring commit, so these
// tests assert structural invariants (registration, license enforcement,
// inventory, A/B, URL resolution) rather than compiling models. When
// the .mlpackage assets are present (Xcode runtime / merged main), the
// load tests will additionally exercise the CoreML compile path; until
// then a `bundleMissing` outcome is accepted as success for the "load"
// half of the tests, because `bundleMissing` proves the license check
// passed before the file-system lookup.
//

import Testing
import Foundation
@testable import ForgeOptimizer

@Suite("ModelRegistry")
struct ModelRegistryTests {

    // MARK: License enforcement

    @Test("Commercial policy refuses Proprietary-Research weights")
    func commercialPolicyRefusesResearchWeights() async {
        let registry = ModelRegistry(policy: .commercial)
        let manifest = ModelManifest(
            role: .qualityRegressor,
            implementation: "quality_regressor",
            version: "0.3.0",
            weightLicense: .ProprietaryResearch,
            bundleResourceName: "quality_regressor",
            inputSize: 224
        )
        await registry.register(manifest)

        await #expect(throws: ModelRegistryError.self) {
            _ = try await registry.load(
                role: .qualityRegressor,
                implementation: "quality_regressor"
            )
        }

        // Verify the *kind* of error is licenseRefused, not bundleMissing.
        do {
            _ = try await registry.load(
                role: .qualityRegressor,
                implementation: "quality_regressor"
            )
            Issue.record("Expected licenseRefused; got success")
        } catch let ModelRegistryError.licenseRefused(license, mode) {
            #expect(license == .ProprietaryResearch)
            #expect(mode == .commercial)
        } catch {
            Issue.record("Expected licenseRefused, got \(error)")
        }
    }

    @Test("Development policy accepts Proprietary-Research weights")
    func developmentPolicyAcceptsResearchWeights() async {
        let registry = ModelRegistry(policy: .development)
        let manifest = ModelManifest(
            role: .qualityRegressor,
            implementation: "quality_regressor",
            version: "0.3.0",
            weightLicense: .ProprietaryResearch,
            bundleResourceName: "quality_regressor",
            inputSize: 224
        )
        await registry.register(manifest)

        // Either it loads (mlpackage present, e.g. Xcode runtime), or it
        // fails with bundleMissing (mlpackage absent in this lineage).
        // Anything else — especially licenseRefused — is a regression.
        do {
            _ = try await registry.load(
                role: .qualityRegressor,
                implementation: "quality_regressor"
            )
        } catch ModelRegistryError.bundleMissing {
            // Expected in the swift-test path; mlpackages not vendored.
        } catch ModelRegistryError.compileFailed {
            // Acceptable if the package is partially staged.
        } catch {
            Issue.record("Unexpected error from development policy: \(error)")
        }
    }

    // MARK: Bundled defaults

    @Test("Bundled v0.3 manifests contain all six expected model names")
    func bundledV03ManifestsCoverSix() async {
        // Use the v0_3BaselineManifests constant directly so we don't
        // race against the `.bundled` lazy registration Task.
        let manifests = ModelRegistry.v0_3BaselineManifests
        #expect(manifests.count == 6)

        let names = Set(manifests.map(\.bundleResourceName))
        #expect(names == [
            "dncnn_color",
            "dncnn_gray",
            "arcnn",
            "espcn_x2",
            "espcn_x4",
            "quality_regressor",
        ])
    }

    @Test("makeBundled registry exposes all six manifests via inventory()")
    func makeBundledInventoryHasSix() async {
        let registry = ModelRegistry.makeBundled(policy: .development)
        // The synchronous factory enqueues registration in an unstructured
        // Task; await an actor message to flush.
        _ = await registry.currentPolicy()
        // Spin briefly until the registration Task has drained; in
        // practice one extra actor hop is enough but we tolerate a small
        // budget for robustness.
        var inventory = await registry.inventory()
        var spins = 0
        while inventory.count < 6 && spins < 50 {
            try? await Task.sleep(nanoseconds: 1_000_000)
            inventory = await registry.inventory()
            spins += 1
        }

        #expect(inventory.count == 6)
        for manifest in inventory {
            #expect(!manifest.weightLicense.rawValue.isEmpty,
                    "manifest \(manifest.implementation) has empty SPDX")
        }
    }

    @Test("v0.3 baseline SPDX matches MODELS.md (5 Proprietary, 1 Proprietary-Research)")
    func bundledSPDXMatches() async {
        let manifests = ModelRegistry.v0_3BaselineManifests
        let proprietary = manifests.filter { $0.weightLicense == .Proprietary }
        let research = manifests.filter { $0.weightLicense == .ProprietaryResearch }
        #expect(proprietary.count == 5)
        #expect(research.count == 1)
        #expect(research.first?.implementation == "quality_regressor")
    }

    // MARK: A/B registration

    @Test("Two implementations under the same role are both retrievable")
    func abRegistrationUnderSameRole() async {
        let registry = ModelRegistry(policy: .development)
        let dncnn = ModelManifest(
            role: .restoration,
            implementation: "dncnn_color",
            version: "0.3.0",
            weightLicense: .Proprietary,
            bundleResourceName: "dncnn_color",
            inputSize: 256
        )
        let nafnet = ModelManifest(
            role: .restoration,
            implementation: "nafnet_color",
            version: "0.4.0-pre",
            weightLicense: .MIT,
            bundleResourceName: "nafnet_color",
            inputSize: 256,
            notes: "Phase B target."
        )
        await registry.register(dncnn)
        await registry.register(nafnet)

        let implementations = await registry.implementations(for: .restoration)
        #expect(implementations.contains("dncnn_color"))
        #expect(implementations.contains("nafnet_color"))
        #expect(implementations.count == 2)

        // Each is independently loadable up to (but not including) the
        // CoreML compile step — i.e. license passes for both.
        for implementation in ["dncnn_color", "nafnet_color"] {
            do {
                _ = try await registry.load(
                    role: .restoration,
                    implementation: implementation
                )
            } catch ModelRegistryError.bundleMissing,
                    ModelRegistryError.compileFailed {
                // OK: license + manifest resolution both succeeded.
            } catch {
                Issue.record("Unexpected error for \(implementation): \(error)")
            }
        }
    }

    // MARK: URL resolution

    @Test("Bundle.module resolves the resource bundle root")
    func bundleModuleResolves() {
        // We only verify the bundle exists. The .mlpackage files may or
        // may not be vendored in this lineage; either is fine.
        let bundle = Bundle.module
        #expect(bundle.bundleURL.path.hasSuffix(".bundle"))
    }

    // MARK: SPDXLicense + LicensePolicy unit tests

    @Test("SPDXLicense.commercialUseAllowed: only Proprietary-Research is false")
    func commercialUseFlag() {
        for license in SPDXLicense.allCases {
            switch license {
            case .ProprietaryResearch:
                #expect(license.commercialUseAllowed == false)
            default:
                #expect(license.commercialUseAllowed == true)
            }
        }
    }

    @Test("LicensePolicy.commercial allow-set excludes Proprietary-Research")
    func commercialAllowSet() {
        #expect(LicensePolicy.commercial.allowedLicenses.contains(.Proprietary))
        #expect(!LicensePolicy.commercial.allowedLicenses.contains(.ProprietaryResearch))
    }

    @Test("LicensePolicy.development allow-set covers every SPDX case")
    func developmentAllowSet() {
        for license in SPDXLicense.allCases {
            #expect(LicensePolicy.development.allowedLicenses.contains(license))
        }
    }

    @Test("ModelManifest Codable round-trips with snake_case JSON keys")
    func manifestCodableSnakeCase() throws {
        let manifest = ModelManifest(
            role: .qualityRegressor,
            implementation: "quality_regressor",
            version: "0.3.0",
            weightLicense: .ProprietaryResearch,
            bundleResourceName: "quality_regressor",
            inputSize: 224,
            notes: "test"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"weight_license\":\"Proprietary-Research\""))
        #expect(json.contains("\"bundle_resource_name\":\"quality_regressor\""))
        #expect(json.contains("\"input_size\":224"))

        let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)
        #expect(decoded == manifest)
    }
}
