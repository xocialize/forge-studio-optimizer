import Testing
import Foundation
import CoreVideo
import ImageBridge
import ForgeOptimizer
@testable import ImageBridgeForge

@Suite("ImageBridgeForge — SigLIP2 still scorer")
struct SigLIP2StillScorerTests {

    @Test("SigLIP2 NR-IQA scores a clean signage still high through the ImageBridge seam")
    func cleanScoresHigh() throws {
        // repo root: …/Packages/ImageBridgeForge/Tests/ImageBridgeForgeTests/<file>
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let backbone = SigLIP2BackboneLoader.defaultCacheRoot.appending(path: "model.safetensors")
        let frame = root.appending(path: "Packages/ForgeTraining/data/iqa_eval_frames/clean_signage.png")
        guard FileManager.default.fileExists(atPath: backbone.path),
              FileManager.default.fileExists(atPath: frame.path) else {
            print("[siglip2-still] backbone/frame absent → skipping (local-only, needs xcodebuild)")
            return
        }

        // Decode the still with ImageBridge, score it with the injected SigLIP2 head.
        let (frames, _) = try ImageBridgeFactory.makeDecoder().decode(url: frame)
        let scorer = try SigLIP2StillScorer()
        let q = scorer.score(reference: frames[0], distorted: frames[0])   // no-ref: reference ignored

        print("[siglip2-still] clean_signage q=\(String(format: "%.3f", q))")
        #expect(q >= 0.0 && q <= 1.0)
        #expect(q > 0.78, "clean signage should score above the gate threshold (got \(q))")
    }
}
