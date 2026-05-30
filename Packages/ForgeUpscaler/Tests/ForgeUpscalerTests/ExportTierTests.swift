// ExportTierTests.swift
//
// Role: Smoke + protocol-conformance tests for the Phase D export tier.
//
// Plan reference: Docs/Forge-CodingPlan-v1.0.md §D
// ADR:           Docs/ADRs/0007-real-esrgan-export-tier.md
//
// TODO (Phase E follow-up): the full Phase D.1 acceptance ("output matches
// PyTorch reference within LPIPS 0.01") is deferred — LPIPS is still a stub
// returning 0 in Packages/ForgeOptimizer/Sources/ForgeOptimizer/Benchmark/
// QualityMeasure.swift. Once that lands, add a numerical-parity test here.

import CoreVideo
import Foundation
import Testing
@testable import ForgeUpscaler

@Suite("ExportTier")
struct ExportTierTests {

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
            throw ExportTierError.inferenceFailed("test fixture: CVPixelBufferCreate -> \(status)")
        }
        // Zero-fill is automatic on creation; lock/unlock once to materialise.
        CVPixelBufferLockBaseAddress(out, [])
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }

    // MARK: - Protocol conformance

    @Test("RealESRGAN_CoreML reports the expected ExportTier surface (x4)")
    func realESRGANCoreMLSurface_x4() throws {
        let tier = try RealESRGAN_CoreML(preset: .general, scale: 4)
        #expect(tier.name == "real-esrgan-coreml")
        #expect(tier.scaleFactor == 4)
        // Vendored mlpackage is fixed at 128×128 input (see Resources/MODELS.md).
        // ADR-0007 documents the deviation from the plan's 256/32 spec.
        #expect(tier.inputTileSize == 128)
        #expect(tier.tileOverlap == 16)
        #expect(tier.inputResolution.width == 128)
        #expect(tier.inputResolution.height == 128)
        #expect(tier.outputResolution.width == 128 * 4)
        #expect(tier.outputResolution.height == 128 * 4)
    }

    @Test("RealESRGAN_CoreML supports scale=2")
    func realESRGANCoreMLSurface_x2() throws {
        let tier = try RealESRGAN_CoreML(preset: .general, scale: 2)
        #expect(tier.scaleFactor == 2)
        #expect(tier.outputResolution.width == 128 * 2)
    }

    @Test("RealESRGAN_CoreML rejects unsupported scale")
    func realESRGANCoreMLRejectsBadScale() {
        #expect(throws: ExportTierError.self) {
            _ = try RealESRGAN_CoreML(preset: .general, scale: 3)
        }
    }

    @Test("RealESRGAN_CoreML resolves preset .anime to the general tier today")
    func animePresetResolvesToGeneral() throws {
        // Until anime-specific Real-ESRGAN weights land (Phase F), .anime
        // must succeed with the general weights and not throw.
        let tier = try RealESRGAN_CoreML(preset: .anime, scale: 4)
        #expect(tier.name == "real-esrgan-coreml")
    }

    // MARK: - OSEDiff stub

    @Test("OSEDiff_MLX stub throws notYetImplemented on upscale")
    func osediffStubThrows() async throws {
        let tier = OSEDiff_MLX(scale: 4)
        #expect(tier.name == "osediff-mlx")
        #expect(tier.scaleFactor == 4)
        #expect(tier.inputTileSize == 256)
        #expect(tier.tileOverlap == 32)

        let buffer = try makeBlankBGRA(width: 64, height: 64)
        await #expect(throws: ExportTierError.self) {
            _ = try await tier.upscale(buffer)
        }
    }

    @Test("OSEDiff_MLX error message references the Q3 revisit trigger")
    func osediffMessageMentionsRevisit() async {
        let tier = OSEDiff_MLX()
        do {
            let buffer = try makeBlankBGRA(width: 64, height: 64)
            _ = try await tier.upscale(buffer)
            Issue.record("expected throw")
        } catch let err as ExportTierError {
            if case .notYetImplemented(let detail) = err {
                #expect(detail.contains("OSEDiff"))
                #expect(detail.contains("2026-Q3") || detail.contains("DiffusionKit"))
            } else {
                Issue.record("unexpected ExportTierError case: \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - ExportUpscaler wrapping the tier

    @Test("ExportUpscaler exposes the wrapped tier and reports its scale")
    func exportUpscalerForwardsTier() throws {
        let upscaler = try ExportUpscaler(preset: .general, scale: 4)
        #expect(upscaler.scale == 4)
        #expect(upscaler.tier.name == "real-esrgan-coreml")
    }

    // MARK: - End-to-end smoke

    @Test("RealESRGAN_CoreML x4 upscales a 256×256 zero frame to 1024×1024")
    func realESRGANSmoke_x4() async throws {
        let tier = try RealESRGAN_CoreML(preset: .general, scale: 4)
        let input = try makeBlankBGRA(width: 256, height: 256)
        let output = try await tier.upscale(input)
        #expect(CVPixelBufferGetWidth(output) == 1024)
        #expect(CVPixelBufferGetHeight(output) == 1024)
        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA)
    }

    @Test("RealESRGAN_CoreML x2 upscales a 256×256 zero frame to 512×512")
    func realESRGANSmoke_x2() async throws {
        let tier = try RealESRGAN_CoreML(preset: .general, scale: 2)
        let input = try makeBlankBGRA(width: 256, height: 256)
        let output = try await tier.upscale(input)
        #expect(CVPixelBufferGetWidth(output) == 512)
        #expect(CVPixelBufferGetHeight(output) == 512)
    }
}
