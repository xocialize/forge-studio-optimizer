//
//  NAFNetProcessorTests.swift
//  ForgeOptimizerTests
//
//  Integration test for Phase B.5 (Task #14): the NAFNetProcessor FrameProcessor
//  loads the bundled trained weights (nafnet.safetensors), runs the MLX model
//  over a real BGRA frame, and returns a same-resolution BGRA buffer. Exercises
//  the full path — Bundle.module weight resolution, BGRA→RGB NHWC conversion,
//  NAFNet's internal pad-to-16 / crop, and RGB→BGRA write-back.
//
//  MLX-Metal suite — runs via `xcodebuild test`, not `swift test`.
//

import Testing
import CoreVideo
import FormatBridge
@testable import ForgeOptimizer

@Suite("NAFNetProcessor (B.5 wiring)")
struct NAFNetProcessorTests {

    /// A BGRA buffer with a deterministic gradient (non-trivial content so the
    /// model has something to restore).
    private func makeBGRA(width w: Int, height h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        _ = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let dst = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let o = y * bpr + x * 4
                dst[o + 0] = UInt8((x * 2) % 256)        // B
                dst[o + 1] = UInt8((y * 2) % 256)        // G
                dst[o + 2] = UInt8((x + y) % 256)        // R
                dst[o + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    @Test("loads bundled weights and restores a frame at its native resolution")
    func loadsAndProcesses() throws {
        let processor = try NAFNetProcessor()           // loads nafnet.safetensors from Bundle.module
        // 130×100 is NOT a multiple of 16 → exercises NAFNet's pad-to-16 + crop.
        let input = makeBGRA(width: 130, height: 100)
        let output = processor.process(input)

        #expect(CVPixelBufferGetWidth(output) == 130)
        #expect(CVPixelBufferGetHeight(output) == 100)
        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA)

        // The output must be readable (a real buffer, not a crash/garbage).
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        #expect(CVPixelBufferGetBaseAddress(output) != nil)
    }

    @Test("drives through PreprocessorFactory for a non-off level")
    func factoryWiring() throws {
        // .balanced must now yield a NAFNet-backed chain (B.5), not the v0.3 stub.
        let chain = try PreprocessorFactory.makeChain(for: .balanced)
        #expect(chain != nil)
        let out = chain!.process(makeBGRA(width: 64, height: 64))
        #expect(CVPixelBufferGetWidth(out) == 64)
        #expect(CVPixelBufferGetHeight(out) == 64)
    }
}
