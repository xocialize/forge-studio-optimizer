import Testing
import AVFoundation
import CoreMedia
import CoreVideo
@testable import FormatBridge

@Suite("VideoToolboxEncoder (ADR-0013 ship encoder)")
struct VideoToolboxEncoderTests {

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
                p[o + 0] = UInt8((x + frame) % 256)
                p[o + 1] = UInt8((y + frame) % 256)
                p[o + 2] = UInt8((x + y) % 256)
                p[o + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    @Test("constant-quality HEVC encode → a decodable HEVC mp4")
    func encodesHEVC() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtenc-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        let encoder = FormatBridgeFactory.makeQualityEncoder()
        let settings = VideoEncoderSettings(
            codec: .hevc, resolution: .p480, frameRate: .target(30),
            constantQuality: 0.5)
        try encoder.configure(output: out, videoSettings: settings, audioSettings: nil)

        for i in 0 ..< 30 {
            try encoder.appendVideoFrame(
                bgra(settings.outputWidth, settings.outputHeight, frame: i * 4),
                at: CMTime(value: Int64(i), timescale: 30),
                duration: CMTime(value: 1, timescale: 30))
        }
        try await encoder.finish()

        #expect(encoder.isHardwareAccelerated)
        #expect(FileManager.default.fileExists(atPath: out.path))
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path)[.size]) as? Int) ?? 0
        #expect(size > 0)

        // It must be a real, decodable HEVC track.
        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let formats = try await tracks[0].load(.formatDescriptions)
        #expect(!formats.isEmpty)
        #expect(CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_HEVC)
    }
}
