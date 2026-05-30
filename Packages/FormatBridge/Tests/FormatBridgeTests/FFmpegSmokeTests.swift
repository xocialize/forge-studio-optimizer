import Testing
import FFmpegXC

@Suite("FFmpeg Linkage Smoke Tests")
struct FFmpegSmokeTests {

    @Test("avformat_version returns a valid version number")
    func avformatVersion() {
        let version = avformat_version()
        // FFmpeg 7.1.x: major version should be >= 61
        let major = version >> 16
        #expect(major >= 61, "Expected avformat major version >= 61, got \(major)")
    }

    @Test("avcodec_version returns a valid version number")
    func avcodecVersion() {
        let version = avcodec_version()
        let major = version >> 16
        #expect(major >= 61, "Expected avcodec major version >= 61, got \(major)")
    }

    @Test("avutil_version returns a valid version number")
    func avutilVersion() {
        let version = avutil_version()
        let major = version >> 16
        #expect(major >= 59, "Expected avutil major version >= 59, got \(major)")
    }

    @Test("swscale_version returns a valid version number")
    func swscaleVersion() {
        let version = swscale_version()
        let major = version >> 16
        #expect(major >= 8, "Expected swscale major version >= 8, got \(major)")
    }

    @Test("swresample_version returns a valid version number")
    func swresampleVersion() {
        let version = swresample_version()
        let major = version >> 16
        #expect(major >= 5, "Expected swresample major version >= 5, got \(major)")
    }

    @Test("av_find_input_format recognizes matroska")
    func findMKVFormat() {
        let fmt = av_find_input_format("matroska")
        #expect(fmt != nil, "Expected to find matroska input format")
    }

    @Test("avcodec_find_decoder finds H.264 decoder")
    func findH264Decoder() {
        let decoder = avcodec_find_decoder(AV_CODEC_ID_H264)
        #expect(decoder != nil, "Expected to find H.264 decoder")
    }

    @Test("avcodec_find_decoder finds VP9 decoder")
    func findVP9Decoder() {
        let decoder = avcodec_find_decoder(AV_CODEC_ID_VP9)
        #expect(decoder != nil, "Expected to find VP9 decoder")
    }
}
