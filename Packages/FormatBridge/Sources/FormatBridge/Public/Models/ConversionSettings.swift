import Foundation

public struct ConversionSettings: Codable, Sendable {
    public var videoCodec: OutputVideoCodec
    public var quality: QualityPreset
    public var resolution: ResolutionMode
    public var frameRate: FrameRateMode
    public var audioCodec: OutputAudioCodec
    public var audioBitrate: Int
    public var audioChannels: AudioChannelMode
    public var preserveMetadata: Bool
    public var preserveChapters: Bool
    public var extractSubtitles: Bool
    public var hardwareAcceleration: Bool
    public var optimization: OptimizationLevel

    public init(
        videoCodec: OutputVideoCodec = .hevc,
        quality: QualityPreset = .high,
        resolution: ResolutionMode = .original,
        frameRate: FrameRateMode = .original,
        audioCodec: OutputAudioCodec = .aac,
        audioBitrate: Int = 256_000,
        audioChannels: AudioChannelMode = .original,
        preserveMetadata: Bool = true,
        preserveChapters: Bool = true,
        extractSubtitles: Bool = true,
        hardwareAcceleration: Bool = true,
        optimization: OptimizationLevel = .off
    ) {
        self.videoCodec = videoCodec
        self.quality = quality
        self.resolution = resolution
        self.frameRate = frameRate
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.audioChannels = audioChannels
        self.preserveMetadata = preserveMetadata
        self.preserveChapters = preserveChapters
        self.extractSubtitles = extractSubtitles
        self.hardwareAcceleration = hardwareAcceleration
        self.optimization = optimization
    }

    // Convenience presets
    public static let fast = ConversionSettings(optimization: .off)
    public static let balanced = ConversionSettings(optimization: .balanced)
    public static let smallFile = ConversionSettings(quality: .medium, optimization: .aggressive)

    /// Marquee digital signage preset — maximum compression with
    /// perceptual quality preservation for static/slow-motion content
    public static let marqueeSignage = ConversionSettings(
        videoCodec: .hevc,
        quality: .medium,
        resolution: .original,
        audioCodec: .aac,
        audioBitrate: 128_000,
        audioChannels: .stereo,
        optimization: .maximum
    )
}
