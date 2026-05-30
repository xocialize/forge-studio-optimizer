import CoreMedia
import Testing

@testable import FormatBridge

@Suite("TierRouter")
struct TierRouterTests {

    private func makeMediaInfo(
        container: ContainerFormat,
        videoCodec: VideoCodec,
        audioCodec: AudioCodec
    ) -> MediaInfo {
        MediaInfo(
            url: URL(fileURLWithPath: "/tmp/test.mkv"),
            container: container,
            duration: CMTimeMake(value: 60, timescale: 1),
            fileSize: 100_000_000,
            videoStreams: [
                VideoStreamInfo(
                    index: 0, codec: videoCodec, width: 1920, height: 1080,
                    frameRate: 24.0, isVFR: false, bitDepth: 8, pixelFormat: "yuv420p",
                    colorSpace: nil, hdrMetadata: nil, bitrate: 5_000_000, isInterlaced: false
                ),
            ],
            audioStreams: [
                AudioStreamInfo(
                    index: 1, codec: audioCodec, channels: 2, channelLayout: "stereo",
                    sampleRate: 48000, bitrate: 128_000, language: "eng", title: nil
                ),
            ],
            subtitleStreams: [],
            chapters: [],
            metadata: [:],
            conversionTier: .hybrid
        )
    }

    @Test("Native MP4 with H.264 + AAC routes to fast path")
    func nativeFastPath() {
        let info = makeMediaInfo(container: .mp4, videoCodec: .h264, audioCodec: .aac)
        let tier = TierRouter.determineTier(mediaInfo: info, settings: .fast)
        #expect(tier == .nativeFastPath)
    }

    @Test("MKV with VP9 + Opus routes to hybrid")
    func hybridTier() {
        let info = makeMediaInfo(container: .mkv, videoCodec: .vp9, audioCodec: .opus)
        let tier = TierRouter.determineTier(mediaInfo: info, settings: .fast)
        #expect(tier == .hybrid)
    }

    @Test("MKV with VP9 + Opus and optimization routes to hybridOptimized")
    func hybridOptimized() {
        let info = makeMediaInfo(container: .mkv, videoCodec: .vp9, audioCodec: .opus)
        let tier = TierRouter.determineTier(mediaInfo: info, settings: .balanced)
        #expect(tier == .hybridOptimized)
    }

    @Test("Native MP4 with H.264 + AAC and optimization routes to nativeOptimized")
    func nativeOptimized() {
        let info = makeMediaInfo(container: .mp4, videoCodec: .h264, audioCodec: .aac)
        let tier = TierRouter.determineTier(mediaInfo: info, settings: .balanced)
        #expect(tier == .nativeOptimized)
    }

    @Test("MKV with H.264 + DTS routes to audio-only re-encode")
    func audioOnlyReencode() {
        let info = makeMediaInfo(container: .mkv, videoCodec: .h264, audioCodec: .dts)
        let tier = TierRouter.determineTier(mediaInfo: info, settings: .fast)
        #expect(tier == .audioOnlyReencode)
    }
}
