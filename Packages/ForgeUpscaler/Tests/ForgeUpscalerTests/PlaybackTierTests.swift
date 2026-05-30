// PlaybackTierTests.swift
//
// Role: Smoke + protocol-conformance tests for the Phase C.5a playback
//       tier. Mirrors `ExportTierTests.swift`.
//
// Plan reference: Docs/Forge-CodingPlan-v1.0.md §C
// ADR:           Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md
//
// CLI vs Xcode runtime split:
//   - The bundle-resolution + pure-value tests at the top of the suite
//     (`Variant.safetensorsName`, `Bundle.module.url(...)`, the
//     `unsupportedScale` check that throws before any MLX init) all pass
//     under `swift test --filter PlaybackTierTests` on the CLI.
//   - The protocol-conformance + backend round-trip tests construct an
//     `EfRLFN_Playback` / `SRVGGNetCompact_Playback`, which builds an
//     underlying MLX module. MLX's first op tries to load the default
//     metallib, which only stages reliably under the Xcode test runner
//     (same as NAFNetTests / EfRLFNTests / SRVGGNetTests' forward path).
//     Those tests live in the `// MARK: - MLX-runtime subset` section.
//
// The brief's acceptance criteria reflect that split: bundle-resolution +
// pure-value tests pass on CLI; MLX-using tests are Xcode-only.

import CoreVideo
import Foundation
import Testing
@testable import ForgeUpscaler

@Suite("PlaybackTier", .serialized)
struct PlaybackTierTests {

    // MARK: - Helpers

    /// Build a zero-filled BGRA `CVPixelBuffer` for smoke tests.
    private func makeBlankBGRA(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let status = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let out = buffer else {
            throw PlaybackTierError.inferenceError("test fixture: CVPixelBufferCreate -> \(status)")
        }
        CVPixelBufferLockBaseAddress(out, [])
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }

    // MARK: - CLI subset: pure-value + bundle resolution
    //
    // None of these touch MLX, so they pass under `swift test` even
    // without a staged Metal library.

    @Test("Variant.safetensorsName maps to the vendored stem")
    func variantSafetensorsNameMapping() {
        #expect(SRVGGNetCompact_Playback.Variant.general.safetensorsName == "realesr_general_x4")
        #expect(SRVGGNetCompact_Playback.Variant.generalWDN.safetensorsName == "realesr_general_wdn_x4")
        #expect(SRVGGNetCompact_Playback.Variant.anime.safetensorsName == "realesr_anime_x4")
    }

    @Test("Bundle resolves EfRLFN x4 safetensors")
    func bundleResolvesEfRLFNWeights() {
        let url = Bundle.module.url(forResource: "efrlfn_x4", withExtension: "safetensors")
        #expect(url != nil, "efrlfn_x4.safetensors must ship in Resources/")
    }

    @Test("Bundle resolves all three SRVGGNetCompact safetensors")
    func bundleResolvesSRVGGNetWeights() {
        for variant in [SRVGGNetCompact_Playback.Variant.general, .generalWDN, .anime] {
            let url = Bundle.module.url(
                forResource: variant.safetensorsName,
                withExtension: "safetensors"
            )
            #expect(url != nil, "\(variant.safetensorsName).safetensors must ship in Resources/")
        }
    }

    @Test("EfRLFN_Playback rejects unsupported scale before any MLX init")
    func efrlfnPlaybackRejectsScale2() {
        // The unsupportedScale guard fires before the module is built, so
        // this test runs cleanly on CLI even without the Metal library.
        // Pinning the x4-only constraint here so the C.5b x2 wiring can't
        // silently regress this gate.
        #expect(throws: PlaybackTierError.self) {
            _ = try EfRLFN_Playback(scale: 2)
        }
        #expect(throws: PlaybackTierError.self) {
            _ = try EfRLFN_Playback(scale: 3)
        }
    }

    // MARK: - MLX-runtime subset (Xcode-only — Metal library)
    //
    // These tests construct an EfRLFN or SRVGGNetCompact MLX module, which
    // requires the Metal library to be staged into the .xctest bundle.
    // From the SwiftPM CLI test runner the metallib doesn't always stage,
    // and MLX-Swift's `Device.withDefaultDevice(Device(.cpu), …)` wrapper
    // doesn't help because the C runtime touches the lib on first device
    // init. Same convention as NAFNetTests / EfRLFNTests / SRVGGNetTests'
    // forward-pass tests.
    //
    // Run from Xcode via Product → Test on the ForgeUpscaler scheme.

    @Test("EfRLFN_Playback reports the expected PlaybackTier surface (x4)")
    func efrlfnPlaybackSurface_x4() throws {
        let tier = try EfRLFN_Playback(scale: 4)
        #expect(tier.name == "efrlfn-x4")
        #expect(tier.scaleFactor == 4)
        #expect(tier.inputTileSize == 128)
        #expect(tier.tileOverlap == 16)
        #expect(tier.inputResolution.width == 128)
        #expect(tier.inputResolution.height == 128)
        #expect(tier.outputResolution.width == 128 * 4)
        #expect(tier.outputResolution.height == 128 * 4)
    }

    @Test("SRVGGNetCompact_Playback instantiates all 3 variants with distinct names")
    func srvggnetPlaybackAllVariants() throws {
        let g = try SRVGGNetCompact_Playback(variant: .general)
        let w = try SRVGGNetCompact_Playback(variant: .generalWDN)
        let a = try SRVGGNetCompact_Playback(variant: .anime)

        #expect(g.name == "srvggnet-general-x4")
        #expect(w.name == "srvggnet-general-wdn-x4")
        #expect(a.name == "srvggnet-anime-x4")

        for tier in [g, w, a] {
            #expect(tier.scaleFactor == 4)
            #expect(tier.inputTileSize == 64)
            #expect(tier.tileOverlap == 8)
            #expect(tier.inputResolution.width == 64)
            #expect(tier.outputResolution.width == 64 * 4)
        }
    }

    @Test("PlaybackUpscaler(backend:) wraps every Backend case")
    func playbackUpscalerBackendRoundTrip() throws {
        let efrlfn = try PlaybackUpscaler(backend: .efrlfn(scale: 4))
        let general = try PlaybackUpscaler(backend: .srvggnetGeneral(scale: 4))
        let generalWDN = try PlaybackUpscaler(backend: .srvggnetGeneralWDN(scale: 4))
        let anime = try PlaybackUpscaler(backend: .srvggnetAnime(scale: 4))

        #expect(efrlfn.scale == 4)
        #expect(efrlfn.tier.name == "efrlfn-x4")
        #expect(general.tier.name == "srvggnet-general-x4")
        #expect(generalWDN.tier.name == "srvggnet-general-wdn-x4")
        #expect(anime.tier.name == "srvggnet-anime-x4")
    }

    @Test("Backend.defaultGeneral / .defaultAnime point at the documented tiers")
    func backendDefaults() throws {
        let general = try PlaybackUpscaler(backend: .defaultGeneral)
        let anime = try PlaybackUpscaler(backend: .defaultAnime)
        // Post-C.4 (ADR-0008): default general is SRVGGNetCompact-general,
        // not EfRLFN — EfRLFN lost the A/B by −26.8 VMAF.
        #expect(general.tier.name == "srvggnet-general-x4")
        #expect(anime.tier.name == "srvggnet-anime-x4")
    }

    @Test("PlaybackUpscaler(scale:preset:) backward-compat: presets route to SRVGGNet (post-C.4)")
    func backwardCompatPresetRouting() throws {
        let general = try PlaybackUpscaler(scale: 4, preset: .general)
        let anime = try PlaybackUpscaler(scale: 4, preset: .anime)
        let signage = try PlaybackUpscaler(scale: 4, preset: .signage)
        let dvd = try PlaybackUpscaler(scale: 4, preset: .dvd)
        // ADR-0008: all non-anime presets route to SRVGGNetCompact-general
        // (the C.4 A/B winner); anime routes to the SRVGGNet anime variant.
        #expect(general.tier.name == "srvggnet-general-x4")
        #expect(anime.tier.name == "srvggnet-anime-x4")
        #expect(signage.tier.name == "srvggnet-general-x4")
        #expect(dvd.tier.name == "srvggnet-general-x4")
    }

    @Test("EfRLFN_Playback upscales a 128×128 zero frame to 512×512")
    func efrlfnPlaybackSmoke_x4() async throws {
        let tier = try EfRLFN_Playback(scale: 4)
        let input = try makeBlankBGRA(width: 128, height: 128)
        let output = try await tier.upscale(input)
        #expect(CVPixelBufferGetWidth(output) == 512)
        #expect(CVPixelBufferGetHeight(output) == 512)
        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA)
    }

    @Test("SRVGGNetCompact_Playback (anime) upscales a 64×64 zero frame to 256×256")
    func srvggnetAnimePlaybackSmoke_x4() async throws {
        let tier = try SRVGGNetCompact_Playback(variant: .anime)
        let input = try makeBlankBGRA(width: 64, height: 64)
        let output = try await tier.upscale(input)
        #expect(CVPixelBufferGetWidth(output) == 256)
        #expect(CVPixelBufferGetHeight(output) == 256)
        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA)
    }
}
