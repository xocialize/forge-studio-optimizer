import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Encodes video frames via VideoToolbox (hardware-accelerated) and audio via CoreAudio AAC,
/// muxing the output to MP4 via AVAssetWriter.
final class NativeEncoderImpl: VideoEncoding, @unchecked Sendable {

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private(set) var isHardwareAccelerated: Bool = false
    private var pendingMetadata: MediaInfo?

    // Deferred-append queues for interleave backpressure (#32).
    // When one track races ahead of the other, AVAssetWriter sets that input's
    // `isReadyForMoreMediaData = false` until the other track catches up. The old
    // code block-spun the append until ready — but the only thing that clears the
    // backpressure is pushing the OTHER track, which the blocked caller can't reach
    // → deadlock (the hybrid WebM/MKV+audio path stalled ~2/3 of the time). Instead
    // we defer the buffer here and return, so the caller pushes the other track and
    // the writer drains. Retaining the decoder's pool buffer is safe: a
    // CVPixelBufferPool will not recycle a still-retained buffer.
    private var pendingVideo: [(CVPixelBuffer, CMTime)] = []
    private var pendingAudio: [CMSampleBuffer] = []

    /// Max wall-clock to drain remaining queued buffers at `finish()` before
    /// failing (time-based, robust to scheduler jitter). Not used on the hot path —
    /// appends never block; this only bounds the final flush.
    private static let readinessTimeout: TimeInterval = 5.0

    /// Throw the writer's real error if it has entered `.failed`.
    private func failIfWriterFailed() throws {
        if let writer = assetWriter, writer.status == .failed {
            throw FormatBridgeError.encoderWriteFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter failed")
        }
    }

    /// Flush as many queued buffers as each input will currently accept (FIFO,
    /// preserving order). Never blocks.
    private func drainPending() {
        while let (pb, t) = pendingVideo.first,
              let input = videoInput, input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor {
            guard adaptor.append(pb, withPresentationTime: t) else { break }
            pendingVideo.removeFirst()
        }
        while let sb = pendingAudio.first,
              let input = audioInput, input.isReadyForMoreMediaData {
            guard input.append(sb) else { break }
            pendingAudio.removeFirst()
        }
    }

    /// Set source metadata to embed in the output file.
    /// Call before `configure()`.
    func setSourceMetadata(_ mediaInfo: MediaInfo) {
        pendingMetadata = mediaInfo
    }

    func configure(output: URL, videoSettings: VideoEncoderSettings, audioSettings: AudioEncoderSettings?) throws {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        assetWriter = writer

        // Video input
        let videoCodec: AVVideoCodecType = videoSettings.codec == .hevc ? .hevc : .h264

        var videoOutputSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: videoSettings.outputWidth,
            AVVideoHeightKey: videoSettings.outputHeight,
        ]

        // VideoToolbox compression properties
        var compressionProps: [String: Any] = [
            AVVideoAllowFrameReorderingKey: true,
            AVVideoExpectedSourceFrameRateKey: videoSettings.outputFrameRate,
        ]

        // Quality mapping
        switch videoSettings.quality {
        case .low:
            compressionProps[AVVideoQualityKey] = 0.25
        case .medium:
            compressionProps[AVVideoQualityKey] = 0.5
        case .high:
            compressionProps[AVVideoQualityKey] = 0.75
        case .maximum:
            compressionProps[AVVideoQualityKey] = 1.0
        }

        // Hardware acceleration is automatically used by AVAssetWriter when available.
        // kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder is a VTCompressionSession
        // property, not valid in AVVideoCompressionPropertiesKey.
        isHardwareAccelerated = true

        // Profile
        if videoCodec == .h264 {
            compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        videoOutputSettings[AVVideoCompressionPropertiesKey] = compressionProps

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        vInput.expectsMediaDataInRealTime = false
        videoInput = vInput

        // Pixel buffer adaptor for appending CVPixelBuffers
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: videoSettings.outputWidth,
            kCVPixelBufferHeightKey as String: videoSettings.outputHeight,
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: sourceAttributes
        )

        writer.add(vInput)

        // Audio input — only configured when the caller supplies audio settings.
        // For video-only sources (e.g., a benchmark clip with no audio track),
        // skip the audio input entirely. Adding an audio input the caller never
        // feeds causes AVAssetWriter to stall after ~40 frames waiting on the
        // missing peer for interleaving.
        if let audioSettings {
            let audioOutputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSettings.sampleRate,
                AVNumberOfChannelsKey: audioSettings.outputChannels,
                AVEncoderBitRateKey: audioSettings.bitrate,
            ]

            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
            aInput.expectsMediaDataInRealTime = false
            audioInput = aInput
            writer.add(aInput)
        } else {
            audioInput = nil
        }

        // Apply source metadata if available (set via applySourceMetadata before startWriting)
        if let meta = pendingMetadata {
            MetadataWriter.applyMetadata(to: writer, from: meta)
        }

        guard writer.startWriting() else {
            throw FormatBridgeError.encoderConfigurationFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter.startWriting failed"
            )
        }
        writer.startSession(atSourceTime: .zero)
    }

    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime, duration: CMTime) throws {
        guard let adaptor = pixelBufferAdaptor, let input = videoInput else {
            throw FormatBridgeError.encoderWriteFailed("Encoder not configured")
        }
        try failIfWriterFailed()
        drainPending()

        // Fast path: no backlog and the input will accept it → append now.
        // Otherwise defer (don't block) so the caller can push the other track and
        // relieve the interleave backpressure; ordering is preserved via the queue.
        if pendingVideo.isEmpty && input.isReadyForMoreMediaData {
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw FormatBridgeError.encoderWriteFailed(
                    assetWriter?.error?.localizedDescription ?? "Failed to append video frame"
                )
            }
        } else {
            pendingVideo.append((pixelBuffer, time))
        }
    }

    func appendAudioSamples(_ sampleBuffer: CMSampleBuffer) throws {
        guard let input = audioInput else {
            // Either configure() wasn't called, or the encoder was configured
            // video-only (audioSettings: nil). Distinguish so callers can tell
            // apart a misconfiguration from an intentional video-only encode.
            if assetWriter == nil {
                throw FormatBridgeError.encoderWriteFailed("Encoder not configured")
            }
            throw FormatBridgeError.encoderWriteFailed(
                "Encoder configured video-only; audio input not available"
            )
        }

        try failIfWriterFailed()
        drainPending()

        if pendingAudio.isEmpty && input.isReadyForMoreMediaData {
            guard input.append(sampleBuffer) else {
                throw FormatBridgeError.encoderWriteFailed(
                    assetWriter?.error?.localizedDescription ?? "Failed to append audio samples"
                )
            }
        } else {
            pendingAudio.append(sampleBuffer)
        }
    }

    func finish() async throws {
        guard let writer = assetWriter else {
            throw FormatBridgeError.encoderWriteFailed("Encoder not configured")
        }

        // Flush any deferred buffers, then mark each input finished. Crucial ordering:
        // mark a track finished AS SOON AS its queue empties. A track that reached EOS
        // first (typically audio) otherwise holds the other input `not-ready` — the
        // writer keeps waiting to interleave with a track it doesn't yet know is done.
        // markAsFinished() releases that backpressure so the trailing track drains.
        // (markAsFinished is one-shot, so guard each with a flag.) Safe to bound-wait
        // here: the decode loop is done, so the writer drains on its own — no deadlock.
        var videoDone = (videoInput == nil)
        var audioDone = (audioInput == nil)
        func markDrainedTracks() {
            if !audioDone && pendingAudio.isEmpty { audioInput?.markAsFinished(); audioDone = true }
            if !videoDone && pendingVideo.isEmpty { videoInput?.markAsFinished(); videoDone = true }
        }
        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        markDrainedTracks()
        while !pendingVideo.isEmpty || !pendingAudio.isEmpty {
            try failIfWriterFailed()
            drainPending()
            markDrainedTracks()
            if pendingVideo.isEmpty && pendingAudio.isEmpty { break }
            if Date() >= deadline {
                throw FormatBridgeError.encoderWriteFailed(
                    "Encoder finish: \(pendingVideo.count) video + \(pendingAudio.count) audio "
                    + "buffers undrained after \(Self.readinessTimeout)s")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        if !videoDone { videoInput?.markAsFinished() }
        if !audioDone { audioInput?.markAsFinished() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw FormatBridgeError.encoderWriteFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter did not complete successfully"
            )
        }
    }
}

// MARK: - Settings Helpers

extension VideoEncoderSettings {
    var outputWidth: Int {
        switch resolution {
        case .original: return 0 // Will be set from source
        case .p2160: return 3840
        case .p1080: return 1920
        case .p720: return 1280
        case .p480: return 854
        case .custom(let w, _): return w
        }
    }

    var outputHeight: Int {
        switch resolution {
        case .original: return 0
        case .p2160: return 2160
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .custom(_, let h): return h
        }
    }

    var outputFrameRate: Double {
        switch frameRate {
        case .original: return 24.0 // Default, will be overridden
        case .target(let fps): return fps
        }
    }
}

extension AudioEncoderSettings {
    var outputChannels: Int {
        switch channels {
        case .original: return 2 // Default to stereo
        case .stereo: return 2
        case .mono: return 1
        }
    }
}
