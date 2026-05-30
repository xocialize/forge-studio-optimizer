import AVFoundation
import CoreMedia
import CoreVideo
import FormatBridge
import Foundation

/// Full offline video upscaling pipeline: Decode → SR → Encode.
/// Integrates with Forge's existing FFmpeg decode + VideoToolbox encode.
public final class ExportPipeline: @unchecked Sendable {

    private let upscaler: ExportUpscaler
    private let temporalBlender: TemporalBlender?

    /// Progress report for the export pipeline.
    public struct ExportProgress: Sendable {
        public let framesCompleted: Int
        public let totalFrames: Int
        public let secondsPerFrame: Double
        public let estimatedTimeRemaining: TimeInterval
        public let percentage: Double
    }

    public init(upscaler: ExportUpscaler, temporalBlender: TemporalBlender? = nil) {
        self.upscaler = upscaler
        self.temporalBlender = temporalBlender
    }

    /// Process an entire video file with upscaling.
    /// - Parameters:
    ///   - inputURL: Source video file
    ///   - outputURL: Destination MP4 at upscaled resolution
    ///   - settings: Conversion settings (codec, quality, etc.)
    ///   - progress: Progress callback
    public func processVideo(
        inputURL: URL,
        outputURL: URL,
        settings: ConversionSettings = .fast,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        // Probe source
        let probe = FormatBridgeFactory.makeProbe()
        let mediaInfo = try await probe.probe(url: inputURL)

        guard let videoStream = mediaInfo.videoStreams.first else {
            throw UpscalerError.noVideoStream
        }

        let srcWidth = videoStream.width
        let srcHeight = videoStream.height
        let outWidth = srcWidth * upscaler.scale
        let outHeight = srcHeight * upscaler.scale
        let frameRate = videoStream.frameRate > 0 ? videoStream.frameRate : 24.0

        // Estimate total frames
        let duration = CMTimeGetSeconds(mediaInfo.duration)
        let totalFrames = Int(duration * frameRate)

        // Decode
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: inputURL)
        defer { decoder.close() }

        // Encode at upscaled resolution
        let encoder = FormatBridgeFactory.makeEncoder()
        let videoSettings = VideoEncoderSettings(
            codec: settings.videoCodec,
            quality: settings.quality,
            resolution: .custom(width: outWidth, height: outHeight),
            frameRate: .target(frameRate),
            hardwareAcceleration: settings.hardwareAcceleration
        )
        let audioSettings = AudioEncoderSettings(
            codec: settings.audioCodec,
            bitrate: settings.audioBitrate,
            channels: settings.audioChannels
        )
        try encoder.configure(output: outputURL, videoSettings: videoSettings, audioSettings: audioSettings)

        // Process frames with decode-ahead buffering:
        // While SR processes frame N, the decoder can prepare frame N+1.
        // This hides decode latency behind SR compute time (~30% throughput gain).
        var frameIndex = 0
        var previousSRFrame: CVPixelBuffer?
        let pipelineStart = CFAbsoluteTimeGetCurrent()

        // Pre-decode first frame
        var nextMedia = try await decoder.decodeNext()

        while let media = nextMedia {
            try Task.checkCancellation()

            // Start decoding next frame immediately (runs concurrently with SR below)
            let decodeTask = Task { try await decoder.decodeNext() }

            switch media {
            case .video(let frame):
                let frameStart = CFAbsoluteTimeGetCurrent()

                // Upscale (runs on CoreML/Neural Engine while decode happens in parallel)
                var srFrame = try upscaler.upscale(frame.pixelBuffer)

                // Temporal blending (if available)
                if let blender = temporalBlender, let prev = previousSRFrame {
                    srFrame = blender.blend(current: srFrame, previous: prev)
                }

                // Encode upscaled frame
                try encoder.appendVideoFrame(srFrame, at: frame.presentationTime, duration: frame.duration)

                previousSRFrame = srFrame
                frameIndex += 1

                if frameIndex % 5 == 0 {
                    let frameElapsed = CFAbsoluteTimeGetCurrent() - frameStart
                    let totalElapsed = CFAbsoluteTimeGetCurrent() - pipelineStart
                    let avgSecondsPerFrame = totalElapsed / Double(frameIndex)
                    let remaining = avgSecondsPerFrame * Double(max(totalFrames - frameIndex, 0))
                    let pct = Double(frameIndex) / Double(max(totalFrames, 1))

                    progress(ExportProgress(
                        framesCompleted: frameIndex,
                        totalFrames: totalFrames,
                        secondsPerFrame: frameElapsed,
                        estimatedTimeRemaining: remaining,
                        percentage: min(pct, 0.99)
                    ))
                }

            case .audio(let buffer):
                try encoder.appendAudioSamples(buffer.sampleBuffer)
            }

            // Await the pre-decoded next frame
            nextMedia = try await decodeTask.value
        }

        try await encoder.finish()

        progress(ExportProgress(
            framesCompleted: totalFrames,
            totalFrames: totalFrames,
            secondsPerFrame: 0,
            estimatedTimeRemaining: 0,
            percentage: 1.0
        ))
    }
}
