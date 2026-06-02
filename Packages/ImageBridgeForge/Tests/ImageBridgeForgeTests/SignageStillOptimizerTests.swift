import Testing
import Foundation
import CoreVideo
import ForgeOptimizer
import ImageBridge
@testable import ImageBridgeForge

@Suite("ImageBridgeForge — SigLIP2-floor still optimizer (Phase 4)")
struct SignageStillOptimizerTests {

    /// Real SigLIP2 + NAFNet → xcodebuild + Metal only. Opt in via the repo-root marker
    /// `.forge_run_mlx` (env vars don't survive the xcodebuild→xctest boundary). Skips
    /// gracefully if the backbone/frame aren't present.
    @Test("optimize ships a smaller-at-floor HEIC than max-quality, and prints the metric curve")
    func optimizeSmallerAtFloor() throws {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marker = repoRoot.appending(path: ".forge_run_mlx").path
        guard ProcessInfo.processInfo.environment["FORGE_RUN_MLX"] != nil
                || FileManager.default.fileExists(atPath: marker) else {
            print("[opt-siglip2] no FORGE_RUN_MLX / .forge_run_mlx marker → skipping (needs xcodebuild + Metal)")
            return
        }
        let backbone = SigLIP2BackboneLoader.defaultCacheRoot.appending(path: "model.safetensors")
        let frame = repoRoot.appending(path: "Packages/ForgeTraining/data/iqa_eval_frames/clean_signage.png")
        guard FileManager.default.fileExists(atPath: backbone.path),
              FileManager.default.fileExists(atPath: frame.path) else {
            print("[opt-siglip2] backbone/frame absent → skipping"); return
        }

        let head = try SigLIP2NRIQAScorer(maxPatches: 8)
        let scorer = SigLIP2StillScorer(head)
        let decoder = ImageBridgeFactory.makeDecoder()
        let encoder = ImageBridgeFactory.makeEncoder()
        let (frames, meta) = try decoder.decode(url: frame)
        let original = frames[0]

        // 1) Validate the METRIC on real data before trusting the search: score the
        //    original + HEIC re-encodes across the quality knob.
        print("[opt-siglip2] original score=\(String(format: "%.3f", scorer.score(reference: original, distorted: original)))")
        let dir = FileManager.default.temporaryDirectory.appending(path: "optq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for q in [1.0, 0.8, 0.6, 0.4] {
            let u = dir.appending(path: "q\(Int(q * 100)).heic")
            try encoder.encode(original, settings: StillEncoderSettings(format: .heic, quality: q),
                               metadata: meta, to: u)
            let (rf, _) = try decoder.decode(url: u)
            let s = scorer.score(reference: original, distorted: rf[0])
            let bytes = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
            print("[opt-siglip2]   q=\(q) score=\(String(format: "%.3f", s)) bytes=\(bytes)")
        }

        // 2) Max-quality baseline for the savings comparison.
        let maxQ = dir.appending(path: "max.heic")
        try encoder.encode(original, settings: StillEncoderSettings(format: .heic, quality: 1.0),
                           metadata: meta, to: maxQ)
        let maxBytes = (try? FileManager.default.attributesOfItem(atPath: maxQ.path)[.size] as? Int) ?? 0

        // 3) The optimizer at the recommended floor (restore off here → isolate the encode search).
        let opt = try SignageStillOptimizer.make(level: .off)
        let out = dir.appending(path: "out.heic")
        let r = try opt.optimize(input: frame, output: out,
                                 settings: SignageStillOptimizer.settings(format: .heic, restore: false))
        let t = try #require(r.target)
        let savings = maxBytes > 0 ? 100.0 * (1 - Double(r.outputBytes) / Double(maxBytes)) : 0
        print("[opt-siglip2] FLOOR=\(SignageStillOptimizer.recommendedFloor) → q=\(String(format: "%.3f", t.quality)) "
            + "score=\(String(format: "%.3f", t.achievedScore)) met=\(t.metTarget) "
            + "bytes=\(r.outputBytes) (max=\(maxBytes), \(String(format: "%.0f", savings))% smaller) probes=\(t.probeCount)")

        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(r.outputBytes > 0)
        #expect(t.metTarget, "the recommended floor should be reachable on clean signage")
        #expect(r.outputBytes <= maxBytes, "the search must not ship larger than max-quality")
    }
}
