import Foundation

/// Determines the conversion tier based on MediaInfo and ConversionSettings.
struct TierRouter {
    /// Determine tier from raw codec/container values (used by FormatProbe before MediaInfo exists).
    static func determineTier(
        container: ContainerFormat,
        videoCodec: VideoCodec?,
        audioCodec: AudioCodec?,
        optimizationEnabled: Bool
    ) -> ConversionTier {
        let hasNativeVideo = videoCodec?.isNativeApple ?? false
        let hasNativeAudio = audioCodec?.isNativeApple ?? true
        let hasNativeContainer = container.isNativeApple
        let wantsOptimization = optimizationEnabled

        return route(hasNativeContainer: hasNativeContainer, hasNativeVideo: hasNativeVideo,
                     hasNativeAudio: hasNativeAudio, wantsOptimization: wantsOptimization)
    }

    static func determineTier(mediaInfo: MediaInfo, settings: ConversionSettings) -> ConversionTier {
        let hasNativeVideo = mediaInfo.videoStreams.first.map { $0.codec.isNativeApple } ?? false
        let hasNativeAudio = mediaInfo.audioStreams.first.map { $0.codec.isNativeApple } ?? true
        let hasNativeContainer = mediaInfo.container.isNativeApple
        let wantsOptimization = settings.optimization != .off

        return route(hasNativeContainer: hasNativeContainer, hasNativeVideo: hasNativeVideo,
                     hasNativeAudio: hasNativeAudio, wantsOptimization: wantsOptimization)
    }

    private static func route(hasNativeContainer: Bool, hasNativeVideo: Bool,
                              hasNativeAudio: Bool, wantsOptimization: Bool) -> ConversionTier {

        // Tier 1+: Native input with AI optimization
        if hasNativeContainer && hasNativeVideo && hasNativeAudio && wantsOptimization {
            return .nativeOptimized
        }

        // Tier 1: Native fast path (remux or re-encode)
        if hasNativeContainer && hasNativeVideo && hasNativeAudio {
            return .nativeFastPath
        }

        // Tier 3: Audio-only re-encode (native video in non-native container, or non-native audio)
        if hasNativeVideo && !hasNativeAudio && !wantsOptimization {
            return .audioOnlyReencode
        }

        // Tier 2+: Hybrid with AI optimization
        if wantsOptimization {
            return .hybridOptimized
        }

        // Tier 2: Hybrid (FFmpeg decode → VideoToolbox encode)
        return .hybrid
    }
}
