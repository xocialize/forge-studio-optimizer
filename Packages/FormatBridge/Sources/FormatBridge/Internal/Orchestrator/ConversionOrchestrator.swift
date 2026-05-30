import CoreMedia
import Foundation

/// Orchestrates the full conversion pipeline: probe → decode → [optimize] → encode.
final class ConversionOrchestrator: ConversionOrchestrating, @unchecked Sendable {
    private let probe: any MediaProbing
    private let frameProcessor: (any FrameProcessor)?

    init(probe: any MediaProbing, frameProcessor: (any FrameProcessor)? = nil) {
        self.probe = probe
        self.frameProcessor = frameProcessor
    }

    func convert(
        input: URL,
        output: URL,
        settings: ConversionSettings,
        progress: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        // Step 1: Probe
        sendProgress(progress, stage: .probing, percentage: 0)

        let mediaInfo = try await probe.probe(url: input)
        let tier = TierRouter.determineTier(mediaInfo: mediaInfo, settings: settings)
        let duration = mediaInfo.duration

        // Step 2: Route to appropriate pipeline
        switch tier {
        case .nativeFastPath:
            let exporter = Tier1Exporter()
            try await exporter.export(input: input, output: output, settings: settings, progress: progress)

        case .hybrid, .audioOnlyReencode:
            try await convertHybrid(
                input: input, output: output, settings: settings,
                mediaInfo: mediaInfo, duration: duration, progress: progress
            )

        case .hybridOptimized, .nativeOptimized:
            try await convertHybrid(
                input: input, output: output, settings: settings,
                mediaInfo: mediaInfo, duration: duration, progress: progress
            )
        }

        // Step 3: Extract subtitles as sidecar files (if enabled and present)
        if settings.extractSubtitles && !mediaInfo.subtitleStreams.isEmpty {
            let outputDir = output.deletingLastPathComponent()
            let baseName = output.deletingPathExtension().lastPathComponent
            let _ = try? SubtitleExtractor.extract(
                from: input,
                to: outputDir,
                baseName: baseName,
                subtitleStreams: mediaInfo.subtitleStreams
            )
        }
    }

    // MARK: - Hybrid Pipeline (Tier 2 + Tier 3)

    private func convertHybrid(
        input: URL,
        output: URL,
        settings: ConversionSettings,
        mediaInfo: MediaInfo,
        duration: CMTime,
        progress: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        let decoder = FFmpegDecoderImpl()
        try await decoder.open(url: input)
        defer { decoder.close() }

        // Resolve output dimensions
        let sourceVideo = mediaInfo.videoStreams.first
        let (outWidth, outHeight) = resolveOutputDimensions(
            settings: settings,
            sourceWidth: sourceVideo?.width ?? 1920,
            sourceHeight: sourceVideo?.height ?? 1080
        )
        let outFrameRate = resolveFrameRate(settings: settings, sourceRate: sourceVideo?.frameRate ?? 24.0)

        // Configure encoder with source metadata
        let encoder = NativeEncoderImpl()
        if settings.preserveMetadata {
            encoder.setSourceMetadata(mediaInfo)
        }
        let videoSettings = VideoEncoderSettings(
            codec: settings.videoCodec,
            quality: settings.quality,
            resolution: .custom(width: outWidth, height: outHeight),
            frameRate: .target(outFrameRate),
            hardwareAcceleration: settings.hardwareAcceleration
        )
        // Only configure an audio input when the source actually has audio.
        // Otherwise AVAssetWriter stalls after ~40 frames waiting on audio
        // packets that will never arrive (see NativeEncoder.configure).
        let audioSettings: AudioEncoderSettings? = mediaInfo.audioStreams.isEmpty ? nil : AudioEncoderSettings(
            codec: settings.audioCodec,
            bitrate: settings.audioBitrate,
            sampleRate: 48_000,
            channels: settings.audioChannels
        )

        try encoder.configure(output: output, videoSettings: videoSettings, audioSettings: audioSettings)

        // Interleaved decode → encode loop
        // Reads packets in demuxer order, dispatching video and audio to their respective
        // encoder inputs. This preserves timestamp ordering required by AVAssetWriter.
        let totalSeconds = CMTimeGetSeconds(duration)
        var framesProcessed = 0
        var audioSamplesWritten = 0
        let startTime = CFAbsoluteTimeGetCurrent()

        sendProgress(progress, stage: .encoding, percentage: 0, duration: duration)

        while let media = try await decoder.decodeNext() {
            try Task.checkCancellation()

            switch media {
            case .video(let frame):
                var pixelBuffer = frame.pixelBuffer

                if let processor = frameProcessor {
                    pixelBuffer = processor.process(pixelBuffer)
                }

                try encoder.appendVideoFrame(pixelBuffer, at: frame.presentationTime, duration: frame.duration)
                framesProcessed += 1

                // Report progress based on video position
                let currentSeconds = CMTimeGetSeconds(frame.presentationTime)
                let pct = totalSeconds > 0 ? currentSeconds / totalSeconds : 0

                if framesProcessed % 10 == 0 {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let speed = elapsed > 0 ? currentSeconds / elapsed : 0
                    let remaining = speed > 0 ? (totalSeconds - currentSeconds) / speed : nil

                    progress(ConversionProgress(
                        percentage: min(pct, 0.99),
                        currentTime: frame.presentationTime,
                        totalDuration: duration,
                        framesProcessed: framesProcessed,
                        estimatedRemaining: remaining,
                        speed: speed,
                        stage: .encoding
                    ))
                }

            case .audio(let buffer):
                do {
                    try encoder.appendAudioSamples(buffer.sampleBuffer)
                    audioSamplesWritten += 1
                } catch {
                    // Non-fatal: skip individual audio buffers that fail to append
                }
            }
        }

        // Finalize
        sendProgress(progress, stage: .finishing, percentage: 0.99, duration: duration)
        try await encoder.finish()

        progress(ConversionProgress(
            percentage: 1.0,
            currentTime: duration,
            totalDuration: duration,
            framesProcessed: framesProcessed,
            estimatedRemaining: 0,
            speed: 0,
            stage: .finishing
        ))
    }

    // MARK: - Helpers

    private func resolveOutputDimensions(settings: ConversionSettings, sourceWidth: Int, sourceHeight: Int) -> (Int, Int) {
        switch settings.resolution {
        case .original: return (sourceWidth, sourceHeight)
        case .p2160: return scalePreserveAspect(targetHeight: 2160, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        case .p1080: return scalePreserveAspect(targetHeight: 1080, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        case .p720: return scalePreserveAspect(targetHeight: 720, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        case .p480: return scalePreserveAspect(targetHeight: 480, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        case .custom(let w, let h): return (w, h)
        }
    }

    private func scalePreserveAspect(targetHeight: Int, sourceWidth: Int, sourceHeight: Int) -> (Int, Int) {
        guard sourceHeight > 0 else { return (targetHeight * 16 / 9, targetHeight) }
        let aspect = Double(sourceWidth) / Double(sourceHeight)
        var width = Int(Double(targetHeight) * aspect)
        // Ensure even dimensions (required by video encoders)
        width = (width + 1) & ~1
        let height = (targetHeight + 1) & ~1
        return (width, height)
    }

    private func resolveFrameRate(settings: ConversionSettings, sourceRate: Double) -> Double {
        switch settings.frameRate {
        case .original: return sourceRate > 0 ? sourceRate : 24.0
        case .target(let fps): return fps
        }
    }

    private func sendProgress(
        _ progress: @escaping @Sendable (ConversionProgress) -> Void,
        stage: ConversionStage,
        percentage: Double,
        duration: CMTime = .zero
    ) {
        progress(ConversionProgress(
            percentage: percentage,
            currentTime: CMTimeMultiplyByFloat64(duration, multiplier: Float64(percentage)),
            totalDuration: duration,
            framesProcessed: 0,
            estimatedRemaining: nil,
            speed: 0,
            stage: stage
        ))
    }
}
