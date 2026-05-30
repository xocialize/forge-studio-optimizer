import AVFoundation
import CoreMedia
import Foundation

/// Handles Tier 1 (Native Fast Path) conversion via AVAssetExportSession.
/// Used when input is already MP4/MOV with H.264/HEVC + native audio.
final class Tier1Exporter: @unchecked Sendable {

    func export(
        input: URL,
        output: URL,
        settings: ConversionSettings,
        progress: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        let asset = AVURLAsset(url: input)

        // Load duration for progress
        let duration = try await asset.load(.duration)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: exportPreset(for: settings)) else {
            throw FormatBridgeError.encoderConfigurationFailed("Failed to create AVAssetExportSession")
        }

        // Remove existing output
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        exportSession.outputURL = output
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        // Progress monitoring
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let p = exportSession.progress
                progress(ConversionProgress(
                    percentage: Double(p),
                    currentTime: CMTimeMultiplyByFloat64(duration, multiplier: Float64(p)),
                    totalDuration: duration,
                    framesProcessed: 0,
                    estimatedRemaining: nil,
                    speed: 0,
                    stage: .encoding
                ))
            }
        }

        await exportSession.export()
        progressTask.cancel()

        switch exportSession.status {
        case .completed:
            progress(ConversionProgress(
                percentage: 1.0,
                currentTime: duration,
                totalDuration: duration,
                framesProcessed: 0,
                estimatedRemaining: 0,
                speed: 0,
                stage: .finishing
            ))
        case .cancelled:
            throw FormatBridgeError.cancelled
        case .failed:
            throw FormatBridgeError.conversionFailed(
                exportSession.error?.localizedDescription ?? "AVAssetExportSession failed"
            )
        default:
            throw FormatBridgeError.conversionFailed("Unexpected export status: \(exportSession.status.rawValue)")
        }
    }

    private func exportPreset(for settings: ConversionSettings) -> String {
        switch settings.quality {
        case .low: return AVAssetExportPresetMediumQuality
        case .medium: return AVAssetExportPresetHighestQuality
        case .high: return AVAssetExportPresetHighestQuality
        case .maximum: return AVAssetExportPresetPassthrough
        }
    }
}
