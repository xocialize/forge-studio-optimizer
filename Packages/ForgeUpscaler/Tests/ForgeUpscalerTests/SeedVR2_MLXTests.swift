// SeedVR2_MLXTests.swift
//
// Runtime e2e validation for the SeedVR2 native-MLX export tier: loads the real
// published int8 weights, runs a patterned frame through SeedVR2_MLX on the GPU,
// and checks the output is a sane 2× upscale (dims + non-degenerate pixels). Saves
// the result to /tmp for a visual look. Skips if the weights dir isn't present
// (set SEEDVR2_INT8_DIR, or use the default dev path). MUST run via xcodebuild
// (metallib). This is the "compile → validated on a real frame" gate.

import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import ForgeUpscaler

@Suite("SeedVR2_MLX export tier (runtime)")
struct SeedVR2_MLXTests {

    private var int8Dir: URL? {
        let path = ProcessInfo.processInfo.environment["SEEDVR2_INT8_DIR"]
            ?? "/Users/dustinnielson/DEV_INT/seedvr2-mlx/dist/SeedVR2-3B-mlx-int8"
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("transformer.safetensors").path) ? url : nil
    }

    /// A BGRA buffer with a gradient + hard edges, so the refiner has structure to work on.
    private func makePatternedBGRA(_ side: Int) throws -> CVPixelBuffer {
        var buf: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
        ]
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buf) == kCVReturnSuccess,
              let out = buf else { throw ExportTierError.inferenceFailed("CVPixelBufferCreate") }
        CVPixelBufferLockBaseAddress(out, [])
        let base = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(out)
        for y in 0 ..< side {
            for x in 0 ..< side {
                let p = base + y * stride + x * 4
                let edge: UInt8 = ((x / 8 + y / 8) % 2 == 0) ? 40 : 0   // checker for sharp edges
                p[0] = UInt8(x * 255 / side)                      // B gradient
                p[1] = UInt8(y * 255 / side)                      // G gradient
                p[2] = UInt8(clamping: Int(x * 255 / side) + Int(edge))  // R gradient + checker
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }

    @Test("SeedVR2_MLX upscales a real frame 2× end-to-end (int8, GPU)")
    func seedvr2EndToEnd() throws {
        guard let dir = int8Dir else {
            print("SKIP: int8 weights not found (set SEEDVR2_INT8_DIR)"); return
        }
        let tier = try SeedVR2_MLX(weightsDirectory: dir, scale: 2)
        #expect(tier.name == "seedvr2-mlx")
        #expect(tier.scaleFactor == 2)

        let input = try makePatternedBGRA(128)
        let output = try awaitUpscale(tier, input)

        // dims = 2×
        #expect(CVPixelBufferGetWidth(output) == 256)
        #expect(CVPixelBufferGetHeight(output) == 256)

        // non-degenerate: pixel values span a range (not flat / all-zero / NaN-collapsed)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let base = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(output)
        var lo: UInt8 = 255, hi: UInt8 = 0
        for y in stride(from: 0, to: 256, by: 7) {
            for x in stride(from: 0, to: 256, by: 7) {
                let v = base[y * rowBytes + x * 4 + 2]   // R channel sample
                lo = Swift.min(lo, v); hi = Swift.max(hi, v)
            }
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        #expect(hi > lo, "output is flat — pipeline likely degenerate")

        // save for a visual look
        let ci = CIImage(cvPixelBuffer: output)
        let ctx = CIContext()
        if let cs = CGColorSpace(name: CGColorSpace.sRGB) {
            try? ctx.writePNGRepresentation(of: ci, to: URL(fileURLWithPath: "/tmp/seedvr2_tier_out.png"),
                                            format: .RGBA8, colorSpace: cs)
        }
        print("SeedVR2_MLX e2e OK: 128→256, R range [\(lo),\(hi)] → /tmp/seedvr2_tier_out.png")
    }

    /// Bridge the async ExportTier.upscale into the sync test.
    private func awaitUpscale(_ tier: SeedVR2_MLX, _ buf: CVPixelBuffer) throws -> CVPixelBuffer {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<CVPixelBuffer, Error>!
        Task { do { result = .success(try await tier.upscale(buf)) } catch { result = .failure(error) }; sem.signal() }
        sem.wait()
        return try result.get()
    }
}
