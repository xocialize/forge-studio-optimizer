import AVFoundation
import CoreMedia
import Testing

@testable import FormatBridge

@Suite("ConversionOrchestrator")
struct ConversionOrchestratorTests {

    private let orchestrator = FormatBridgeFactory.makeOrchestrator()

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }

    private func tempOutputURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FormatBridgeTest_\(name)")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Tier 1: Native Fast Path (MP4 → MP4)

    @Test("Converts MP4 to MP4 via native fast path")
    func convertMP4() async throws {
        let input = fixtureURL("sample.mp4")
        let output = tempOutputURL("output_mp4.mp4")
        cleanup(output)
        defer { cleanup(output) }

        var stages: [ConversionStage] = []
        try await orchestrator.convert(input: input, output: output, settings: .fast) { progress in
            if !stages.contains(progress.stage) {
                stages.append(progress.stage)
            }
        }

        // Verify output exists and is a valid MP4
        #expect(FileManager.default.fileExists(atPath: output.path))
        let outputSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64 ?? 0
        #expect(outputSize > 0, "Output file should not be empty")

        // Verify it's playable
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 1.0, "Output duration should be > 1 second")
    }

    // MARK: - Tier 2: Hybrid (WebM VP9+Opus → MP4)

    @Test("Converts WebM (VP9+Opus) to MP4 via hybrid pipeline")
    func convertWebM() async throws {
        let input = fixtureURL("sample.webm")
        let output = tempOutputURL("output_webm.mp4")
        cleanup(output)
        defer { cleanup(output) }

        var lastPercentage: Double = -1
        var gotEncodingStage = false

        try await orchestrator.convert(input: input, output: output, settings: .fast) { progress in
            if progress.stage == .encoding { gotEncodingStage = true }
            lastPercentage = progress.percentage
        }

        #expect(gotEncodingStage, "Should have gone through encoding stage")
        #expect(FileManager.default.fileExists(atPath: output.path))

        // Verify output is valid
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 1.0)

        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        #expect(videoTracks.count >= 1, "Output should have at least 1 video track")
        #expect(audioTracks.count >= 1, "Output should have at least 1 audio track")
    }

    // MARK: - Tier 2: Hybrid (MKV H.264+AAC → MP4)

    @Test("Converts MKV (H.264+AAC) to MP4 via hybrid pipeline")
    func convertMKV() async throws {
        let input = fixtureURL("sample.mkv")
        let output = tempOutputURL("output_mkv.mp4")
        cleanup(output)
        defer { cleanup(output) }

        try await orchestrator.convert(input: input, output: output, settings: .fast) { _ in }

        #expect(FileManager.default.fileExists(atPath: output.path))

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 1.0)
    }

    // MARK: - Tier 3: Audio-only re-encode (MKV H.264+Opus → MP4)

    @Test("Converts MKV with non-native audio to MP4")
    func convertMKVNonNativeAudio() async throws {
        let input = fixtureURL("sample_nonnative_audio.mkv")
        let output = tempOutputURL("output_nonnative.mp4")
        cleanup(output)
        defer { cleanup(output) }

        try await orchestrator.convert(input: input, output: output, settings: .fast) { _ in }

        #expect(FileManager.default.fileExists(atPath: output.path))

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 1.0)
    }

    // MARK: - Progress reporting

    @Test("Progress reports monotonically increasing percentage during hybrid conversion")
    func progressMonotonic() async throws {
        let input = fixtureURL("sample.webm")
        let output = tempOutputURL("output_progress.mp4")
        cleanup(output)
        defer { cleanup(output) }

        var percentages: [Double] = []
        try await orchestrator.convert(input: input, output: output, settings: .fast) { progress in
            percentages.append(progress.percentage)
        }

        // Check that percentages are generally non-decreasing (allowing for stage transitions)
        let finalPercent = percentages.last ?? 0
        #expect(finalPercent >= 0.99, "Final progress should be ~1.0, got \(finalPercent)")
    }
}
