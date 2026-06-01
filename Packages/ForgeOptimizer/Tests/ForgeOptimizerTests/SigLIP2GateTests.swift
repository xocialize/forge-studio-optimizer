//
//  SigLIP2GateTests.swift
//  ForgeOptimizerTests
//
//  End-to-end proof that the wired Swift gate (SigLIP2NRIQAScorer = dequantized
//  8-bit backbone + trained v2 head) reproduces the Python eval's separation on
//  the REAL frames (ADR-0016): clean masters score high, degradation-where-NAFNet-
//  helps (synthetic crush, low-res MPEG-2) scores low. Gated on the locally-cached
//  backbone + off-repo head + eval frames (CI without them skips). Run via
//  `xcodebuild test -scheme ForgeOptimizer-Package` (MLX needs the staged metallib).
//

import Testing
import Foundation
import CoreVideo
import CoreImage
@testable import ForgeOptimizer

@Suite("SigLIP2 NR-IQA gate (real frames)")
struct SigLIP2GateTests {

    @Test("clean frames score above degradation NAFNet helps — separation holds in Swift")
    func gateSeparation() throws {
        // Repo root from this file: …/Packages/ForgeOptimizer/Tests/ForgeOptimizerTests/<file>
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = root.appending(path: "Packages/ForgeTraining/data")
        let backbone = SigLIP2BackboneLoader.defaultCacheRoot.appending(path: "model.safetensors")
        let head = data.appending(path: "iqa_head2/siglip2_iqa_head.safetensors")
        let frames = data.appending(path: "iqa_eval_frames")

        guard FileManager.default.fileExists(atPath: backbone.path),
              FileManager.default.fileExists(atPath: head.path),
              FileManager.default.fileExists(atPath: frames.appending(path: "clean_signage.png").path) else {
            print("[gate] backbone/head/eval-frames absent → skipping (local-only integration test)")
            return
        }

        let scorer = try SigLIP2NRIQAScorer(backboneWeightsURL: backbone, headWeightsURL: head)
        let names = ["clean_sports", "clean_talkinghead", "clean_signage", "crush_crf45",
                     "bad_045", "bad_094", "bad_dvd", "bad_dvd4"]
        var q: [String: Float] = [:]
        for n in names {
            guard let pb = loadPNG(frames.appending(path: "\(n).png")) else {
                Issue.record("failed to load \(n).png"); continue
            }
            q[n] = scorer.quality(pb)
        }
        for n in names {
            print("[gate] \(n.padding(toLength: 18, withPad: " ", startingAt: 0)) \(q[n].map { String(format: "%.3f", $0) } ?? "—")")
        }

        let cleanMin = ["clean_sports", "clean_talkinghead", "clean_signage"]
            .compactMap { q[$0] }.min() ?? 0
        // The cases where NAFNet measurably helps must gate BELOW the clean floor.
        #expect((q["crush_crf45"] ?? 1) < cleanMin, "synthetic crush should score below clean")
        #expect((q["bad_dvd4"] ?? 1) < cleanMin, "low-res MPEG-2 (dvd4) should score below clean")
        // Flat-vector 045/094 are EXPECTED high (restoration is a wash — ADR-0016),
        // so we don't require them low; just record for visibility above.
    }

    @Test("default-on factory: convenience init loads the BUNDLED head + cached backbone")
    func bundledScorerLoads() throws {
        let backbone = SigLIP2BackboneLoader.defaultCacheRoot.appending(path: "model.safetensors")
        guard FileManager.default.fileExists(atPath: backbone.path) else {
            print("[gate] backbone not cached → skipping convenience-init test"); return
        }
        // Convenience init resolves the head from Bundle.module (shipped Resources)
        // — this is the path makeGatedChain/makeChain use by default (ADR-0016).
        let scorer = try SigLIP2NRIQAScorer()

        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let frame = root.appending(path: "Packages/ForgeTraining/data/iqa_eval_frames/clean_signage.png")
        guard let pb = loadPNG(frame) else { print("[gate] eval frame absent → skip"); return }
        let q = scorer.quality(pb)
        print("[gate] convenience-init clean_signage \(String(format: "%.3f", q))")
        #expect(q > 0.78, "clean signage should score above the 0.78 gate threshold")
    }

    /// PNG → BGRA `CVPixelBuffer`.
    private func loadPNG(_ url: URL) -> CVPixelBuffer? {
        guard let ci = CIImage(contentsOf: url) else { return nil }
        let w = Int(ci.extent.width.rounded()), h = Int(ci.extent.height.rounded())
        guard w > 0, h > 0 else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CIContext().render(ci, to: buf)
        return buf
    }
}
