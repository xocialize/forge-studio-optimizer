import CoreMedia
import Testing

@testable import FormatBridge

@Suite("FormatProbe")
struct FormatProbeTests {

    private let probe = FormatBridgeFactory.makeProbe()

    private func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle.module
        return bundle.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }

    // MARK: - MP4 (H.264 + AAC)

    @Test("Probes MP4 with H.264 video and AAC audio")
    func probeMP4() async throws {
        let info = try await probe.probe(url: fixtureURL("sample.mp4"))

        #expect(info.container == .mp4)
        #expect(info.videoStreams.count == 1)
        #expect(info.audioStreams.count == 1)

        let video = info.videoStreams[0]
        #expect(video.codec == .h264)
        #expect(video.width == 320)
        #expect(video.height == 240)
        #expect(video.frameRate > 23.0 && video.frameRate < 25.0)
        #expect(video.bitDepth == 8)

        let audio = info.audioStreams[0]
        #expect(audio.codec == .aac)
        #expect(audio.channels == 1 || audio.channels == 2)

        #expect(info.conversionTier == .nativeFastPath)
        #expect(CMTimeGetSeconds(info.duration) > 1.5)
        #expect(info.fileSize > 0)
    }

    // MARK: - WebM (VP9 + Opus)

    @Test("Probes WebM with VP9 video and Opus audio")
    func probeWebM() async throws {
        let info = try await probe.probe(url: fixtureURL("sample.webm"))

        #expect(info.container == .webm)
        #expect(info.videoStreams.count == 1)
        #expect(info.audioStreams.count == 1)

        let video = info.videoStreams[0]
        #expect(video.codec == .vp9)
        #expect(video.width == 320)
        #expect(video.height == 240)

        let audio = info.audioStreams[0]
        #expect(audio.codec == .opus)

        #expect(info.conversionTier == .hybrid)
    }

    // MARK: - MKV (H.264 + AAC)

    @Test("Probes MKV with H.264 video and AAC audio")
    func probeMKV() async throws {
        let info = try await probe.probe(url: fixtureURL("sample.mkv"))

        #expect(info.container == .mkv)
        #expect(info.videoStreams.count == 1)
        #expect(info.audioStreams.count == 1)

        let video = info.videoStreams[0]
        #expect(video.codec == .h264)

        let audio = info.audioStreams[0]
        #expect(audio.codec == .aac)

        // MKV with native codecs but non-native container → hybrid (re-containerize)
        #expect(info.conversionTier == .hybrid)
    }

    // MARK: - MKV with non-native audio (H.264 + Opus)

    @Test("Probes MKV with H.264 video and Opus audio — tier 3 audio-only re-encode")
    func probeMKVNonNativeAudio() async throws {
        let info = try await probe.probe(url: fixtureURL("sample_nonnative_audio.mkv"))

        #expect(info.container == .mkv)
        let video = info.videoStreams[0]
        #expect(video.codec == .h264)

        let audio = info.audioStreams[0]
        #expect(audio.codec == .opus)

        #expect(info.conversionTier == .audioOnlyReencode)
    }

    // MARK: - Error cases

    @Test("Probe throws fileNotFound for missing file")
    func probeMissingFile() async {
        await #expect(throws: FormatBridgeError.self) {
            try await probe.probe(url: URL(fileURLWithPath: "/nonexistent/file.mkv"))
        }
    }
}
