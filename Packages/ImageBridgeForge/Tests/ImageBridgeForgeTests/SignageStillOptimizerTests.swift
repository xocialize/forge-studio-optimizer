import Testing
import Foundation
import CoreVideo
import ForgeOptimizer
import ImageBridge
@testable import ImageBridgeForge

@Suite("ImageBridgeForge — signage still optimizer (SigLIP2 gate + SSIMULACRA2 floor, #71)")
struct SignageStillOptimizerTests {

    /// Real SigLIP2 (MLX) + the ssimulacra2 binary → xcodebuild + Metal only. Opt in via the
    /// repo-root marker `.forge_run_mlx`; skips gracefully if backbone / frame / binary absent.
    @Test("end-to-end: gate-restore then ship the smallest HEIC clearing the SSIMULACRA2 floor")
    func endToEnd() throws {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marker = repoRoot.appending(path: ".forge_run_mlx").path
        guard ProcessInfo.processInfo.environment["FORGE_RUN_MLX"] != nil
                || FileManager.default.fileExists(atPath: marker) else {
            print("[opt-s2] no FORGE_RUN_MLX / marker → skipping (needs xcodebuild + Metal)"); return
        }
        let backbone = SigLIP2BackboneLoader.defaultCacheRoot.appending(path: "model.safetensors")
        let frame = repoRoot.appending(path: "Packages/ForgeTraining/data/iqa_eval_frames/clean_signage.png")
        guard FileManager.default.fileExists(atPath: backbone.path),
              FileManager.default.fileExists(atPath: frame.path),
              BinarySSIMULACRA2Scorer.isAvailable() else {
            print("[opt-s2] backbone/frame/ssimulacra2 absent → skipping"); return
        }

        // SigLIP2 drives the restoration gate; SSIMULACRA2 drives the lossy floor.
        let opt = try SignageStillOptimizer.make(level: .balanced)
        let dir = FileManager.default.temporaryDirectory.appending(path: "opts2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "out.heic")

        let r = try opt.optimize(input: frame, output: out, settings: SignageStillOptimizer.settings(format: .heic))
        let t = try #require(r.target)
        let maxBytes: Int = {
            let u = dir.appending(path: "max.heic")
            try? ImageBridgeFactory.makeEncoder().encode(
                ImageBridgeFactory.makeDecoder().decode(url: frame).frames[0],
                settings: StillEncoderSettings(format: .heic, quality: 1.0), metadata: nil, to: u)
            return (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        }()
        let savings = maxBytes > 0 ? 100.0 * (1 - Double(r.outputBytes) / Double(maxBytes)) : 0
        print("[opt-s2] floor=\(SignageStillOptimizer.recommendedFloor) → q=\(String(format: "%.3f", t.quality)) "
            + "S2=\(String(format: "%.2f", t.achievedScore)) met=\(t.metTarget) bytes=\(r.outputBytes) "
            + "(max=\(maxBytes), \(String(format: "%.0f", savings))% smaller)")

        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(t.metTarget, "SSIMULACRA2 floor should be reachable on clean signage")
        #expect(t.achievedScore >= SignageStillOptimizer.recommendedFloor - 1.0)
        #expect(r.outputBytes <= maxBytes)
    }
}
