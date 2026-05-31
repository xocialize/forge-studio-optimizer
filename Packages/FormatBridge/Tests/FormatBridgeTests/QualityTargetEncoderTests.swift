import Testing
import AVFoundation
import CoreMedia
import CoreVideo
@testable import FormatBridge

/// Integration tests: the search driving the REAL Step-0 VideoToolbox encoder.
/// VMAF is the one injected seam — these scorers are deterministic so the test
/// is hermetic (no ffmpeg, no model file), while the encode is genuinely real.
@Suite("VideoToolboxQualityTargetEncoder (Step 1 wiring)")
struct QualityTargetEncoderTests {

    // MARK: scorers

    /// Returns a fixed score regardless of input — exercises the boundary paths.
    private struct ConstantScorer: QualityScoring {
        let value: Double
        func score(reference: URL, distorted: URL) async throws -> Double { value }
    }

    /// Recovers the probe quality from the probe filename (`...-<q*1000>.mp4`)
    /// and maps it through a monotone curve. Lets a *real* multi-probe search run
    /// through the real encoder deterministically (the encoder still encodes each
    /// probe; only the metric is synthetic, as real VMAF belongs in the runner).
    private struct QualityFromNameScorer: QualityScoring {
        func score(reference: URL, distorted: URL) async throws -> Double {
            let name = distorted.deletingPathExtension().lastPathComponent
            let milli = Double(name.split(separator: "-").last ?? "0") ?? 0
            let q = milli / 1000.0
            return 80.0 + 20.0 * q
        }
    }

    // MARK: frame source

    private func bgra(_ w: Int, _ h: Int, frame: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        _ = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let o = y * bpr + x * 4
                p[o + 0] = UInt8((x &+ frame) & 255)
                p[o + 1] = UInt8((y &+ frame) & 255)
                p[o + 2] = UInt8((x ^ y) & 255)
                p[o + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    private func frames(_ n: Int, _ w: Int = 256, _ h: Int = 256) -> [CVPixelBuffer] {
        (0 ..< n).map { bgra(w, h, frame: $0 * 4) }
    }

    private func assertDecodableHEVC(_ url: URL) async throws {
        #expect(FileManager.default.fileExists(atPath: url.path))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let fmts = try await tracks[0].load(.formatDescriptions)
        #expect(!fmts.isEmpty)
        #expect(CMFormatDescriptionGetMediaSubType(fmts[0]) == kCMVideoCodecType_HEVC)
    }

    private func makeSettings() -> VideoEncoderSettings {
        VideoEncoderSettings(codec: .hevc, resolution: .original, frameRate: .target(30))
    }

    // MARK: tests

    @Test("scorer always passes → picks the floor quality (max savings)")
    func floorWins() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtqt-floor-\(UUID().uuidString).mp4")
        let ref = FileManager.default.temporaryDirectory.appendingPathComponent("ref.mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        let search = QualityTargetSearch(targetScore: 95, slack: 0.5)
        let enc = FormatBridgeFactory.makeQualityTargetEncoder(
            scorer: ConstantScorer(value: 100), search: search)
        let r = try await enc.encode(frames: frames(24), reference: ref,
                                     output: out, settings: makeSettings())

        #expect(r.metTarget)
        #expect(r.quality == search.qualityRange.lowerBound)
        #expect(r.probeCount == 2)
        try await assertDecodableHEVC(out)
    }

    @Test("scorer never passes → falls back to the ceiling quality")
    func ceilingFallback() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtqt-ceil-\(UUID().uuidString).mp4")
        let ref = FileManager.default.temporaryDirectory.appendingPathComponent("ref.mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        let search = QualityTargetSearch(targetScore: 95, slack: 0.5)
        let enc = FormatBridgeFactory.makeQualityTargetEncoder(
            scorer: ConstantScorer(value: 50), search: search)
        let r = try await enc.encode(frames: frames(24), reference: ref,
                                     output: out, settings: makeSettings())

        #expect(!r.metTarget)
        #expect(r.quality == search.qualityRange.upperBound)
        #expect(r.probeCount == 1)
        try await assertDecodableHEVC(out)
    }

    @Test("a real multi-probe search lands on a mid quality and encodes")
    func midRangeSearch() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtqt-mid-\(UUID().uuidString).mp4")
        let ref = FileManager.default.temporaryDirectory.appendingPathComponent("ref.mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        let search = QualityTargetSearch(targetScore: 95, slack: 0.5)   // need q ≥ 0.725
        let enc = FormatBridgeFactory.makeQualityTargetEncoder(
            scorer: QualityFromNameScorer(), search: search)
        let r = try await enc.encode(frames: frames(24), reference: ref,
                                     output: out, settings: makeSettings())

        #expect(r.metTarget)
        #expect(r.quality >= 0.70 && r.quality <= 0.80)
        #expect(r.probeCount > 2 && r.probeCount <= search.maxProbes)
        try await assertDecodableHEVC(out)
    }
}
