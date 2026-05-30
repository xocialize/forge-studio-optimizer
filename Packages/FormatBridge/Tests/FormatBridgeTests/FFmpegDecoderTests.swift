import CoreMedia
import CoreVideo
import Testing

@testable import FormatBridge

@Suite("FFmpegDecoder")
struct FFmpegDecoderTests {

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }

    @Test("Decodes video frames from MP4")
    func decodeMP4VideoFrames() async throws {
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: fixtureURL("sample.mp4"))
        defer { decoder.close() }

        var frameCount = 0
        while let frame = try await decoder.decodeNextVideoFrame() {
            #expect(frame.pixelBuffer.width == 320)
            #expect(frame.pixelBuffer.height == 240)
            #expect(CMTimeGetSeconds(frame.presentationTime) >= 0)
            frameCount += 1
            if frameCount >= 5 { break }
        }
        #expect(frameCount == 5, "Expected at least 5 video frames")
    }

    @Test("Decodes video frames from WebM (VP9)")
    func decodeWebMVideoFrames() async throws {
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: fixtureURL("sample.webm"))
        defer { decoder.close() }

        var frameCount = 0
        while let frame = try await decoder.decodeNextVideoFrame() {
            #expect(frame.pixelBuffer.width == 320)
            #expect(frame.pixelBuffer.height == 240)
            frameCount += 1
            if frameCount >= 5 { break }
        }
        #expect(frameCount == 5, "Expected at least 5 VP9 frames")
    }

    @Test("Decodes video frames from MKV (H.264)")
    func decodeMKVVideoFrames() async throws {
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: fixtureURL("sample.mkv"))
        defer { decoder.close() }

        var frameCount = 0
        while let frame = try await decoder.decodeNextVideoFrame() {
            #expect(frame.pixelBuffer.width == 320)
            #expect(frame.pixelBuffer.height == 240)
            frameCount += 1
            if frameCount >= 5 { break }
        }
        #expect(frameCount == 5)
    }

    @Test("Decoded pixel buffers are NV12 format")
    func pixelBufferFormat() async throws {
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: fixtureURL("sample.mp4"))
        defer { decoder.close() }

        let frame = try await decoder.decodeNextVideoFrame()
        #expect(frame != nil)
        #expect(frame!.pixelBuffer.pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test("Presentation times increase monotonically")
    func monotonicPTS() async throws {
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: fixtureURL("sample.mp4"))
        defer { decoder.close() }

        var lastPTS: Double = -1
        var count = 0
        while let frame = try await decoder.decodeNextVideoFrame() {
            let pts = CMTimeGetSeconds(frame.presentationTime)
            #expect(pts >= lastPTS, "PTS should be monotonically increasing: \(pts) < \(lastPTS)")
            lastPTS = pts
            count += 1
            if count >= 20 { break }
        }
    }

    @Test("Decodes audio buffers from MP4")
    func decodeAudioBuffers() async throws {
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: fixtureURL("sample.mp4"))
        defer { decoder.close() }

        var bufferCount = 0
        while let buffer = try await decoder.decodeNextAudioBuffer() {
            #expect(CMTimeGetSeconds(buffer.presentationTime) >= 0)
            bufferCount += 1
            if bufferCount >= 5 { break }
        }
        #expect(bufferCount >= 1, "Expected at least 1 audio buffer")
    }

    @Test("Seek resets decode position")
    func seekAndDecode() async throws {
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: fixtureURL("sample.mp4"))
        defer { decoder.close() }

        // Decode a frame, seek to beginning, decode again
        let firstFrame = try await decoder.decodeNextVideoFrame()
        #expect(firstFrame != nil)

        try await decoder.seek(to: .zero)

        let afterSeek = try await decoder.decodeNextVideoFrame()
        #expect(afterSeek != nil)
        // After seeking to 0, PTS should be near 0
        let pts = CMTimeGetSeconds(afterSeek!.presentationTime)
        #expect(pts < 0.5, "After seek to 0, PTS should be near start, got \(pts)")
    }
}
