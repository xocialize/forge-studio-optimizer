import AVFoundation
import CoreMedia
import CoreVideo
import Testing

@testable import FormatBridge

/// Tests that exercise `NativeEncoderImpl` directly, without going through the
/// orchestrator. Focused on the video-only path (audioSettings: nil), which
/// previously stalled `AVAssetWriter` after ~40 frames waiting on an audio
/// peer that never received samples.
@Suite("NativeEncoder")
struct NativeEncoderTests {

    private func tempOutputURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FormatBridgeTest_\(name)")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Synthesize an NV12 pixel buffer of the requested size and paint a
    /// gradient that varies with `frameIndex` so the encoder sees changing
    /// content (a flat buffer can compress to a degenerate stream).
    private func makePixelBuffer(width: Int, height: Int, frameIndex: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw FormatBridgeError.encoderWriteFailed("CVPixelBufferCreate failed: \(status)")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        // Y plane — animated diagonal gradient.
        if let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let yPtr = yPlane.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width {
                    yPtr[row * stride + col] = UInt8((row &+ col &+ frameIndex) & 0xFF)
                }
            }
        }
        // UV plane — neutral chroma (128) for grayscale-ish output.
        if let uvPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let uvPtr = uvPlane.assumingMemoryBound(to: UInt8.self)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, 1)
            for row in 0..<rows {
                for col in 0..<stride {
                    uvPtr[row * stride + col] = 128
                }
            }
        }
        return buffer
    }

    /// Smoke test for the bug this change fixes: a 10-second video-only
    /// encode used to stall after ~40 frames because `NativeEncoder` always
    /// configured an audio input alongside the video input. With
    /// `audioSettings: nil` the encoder now skips audio configuration and
    /// the writer drains video continuously.
    ///
    /// Bounded by `withTimeLimit` so a regression fails the test instead of
    /// hanging the suite.
    @Test("Video-only encode (10s @ 30fps) completes without stalling", .timeLimit(.minutes(1)))
    func videoOnlyEncodeCompletes() async throws {
        let width = 320
        let height = 240
        let frameRate = 30.0
        let totalFrames = 300  // 10 seconds at 30 fps
        let output = tempOutputURL("video_only_smoke.mp4")
        cleanup(output)
        defer { cleanup(output) }

        let encoder = NativeEncoderImpl()
        let videoSettings = VideoEncoderSettings(
            codec: .h264,
            quality: .medium,
            resolution: .custom(width: width, height: height),
            frameRate: .target(frameRate),
            hardwareAcceleration: true
        )

        // The defining call: nil audio settings → video-only output.
        try encoder.configure(output: output, videoSettings: videoSettings, audioSettings: nil)

        // Push frames far beyond the historical stall point (~40 frames).
        for i in 0..<totalFrames {
            let pixelBuffer = try makePixelBuffer(width: width, height: height, frameIndex: i)
            let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(frameRate))
            let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            try encoder.appendVideoFrame(pixelBuffer, at: pts, duration: duration)
        }

        try await encoder.finish()

        // The file must exist, be non-empty, and have ~10s of video.
        #expect(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        #expect(seconds > 9.0 && seconds < 11.0,
                "Output duration should be ~10s, got \(seconds)s")

        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        #expect(videoTracks.count == 1, "Expected exactly 1 video track, got \(videoTracks.count)")
        #expect(audioTracks.isEmpty, "Expected no audio tracks, got \(audioTracks.count)")
    }

    /// `appendAudioSamples` must surface a clear error when the encoder was
    /// configured video-only — callers shouldn't silently lose audio data.
    @Test("Pushing audio to a video-only encoder throws")
    func videoOnlyRejectsAudio() async throws {
        let output = tempOutputURL("video_only_reject_audio.mp4")
        cleanup(output)
        defer { cleanup(output) }

        let encoder = NativeEncoderImpl()
        let videoSettings = VideoEncoderSettings(
            codec: .h264,
            quality: .medium,
            resolution: .custom(width: 320, height: 240),
            frameRate: .target(30.0),
            hardwareAcceleration: true
        )
        try encoder.configure(output: output, videoSettings: videoSettings, audioSettings: nil)

        // Build a minimal silent PCM sample buffer to attempt the append.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        let fdStatus = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        #expect(fdStatus == noErr)

        let frames = 1024
        let byteCount = frames * 8
        var block: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        #expect(bbStatus == noErr)
        guard let block else { return }

        var sb: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: formatDesc!,
            sampleCount: frames, presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &sb
        )
        #expect(sbStatus == noErr)
        guard let sb else { return }

        do {
            try encoder.appendAudioSamples(sb)
            Issue.record("appendAudioSamples should have thrown on video-only encoder")
        } catch {
            // Expected.
        }

        // Push one video frame and finish cleanly so we don't leak the
        // AVAssetWriter on its serial queue.
        let pb = try makePixelBuffer(width: 320, height: 240, frameIndex: 0)
        try encoder.appendVideoFrame(pb, at: .zero, duration: CMTime(value: 1, timescale: 30))
        try await encoder.finish()
    }
}
