import Foundation

public struct VideoEncoderSettings: Sendable {
    public var codec: OutputVideoCodec
    public var quality: QualityPreset
    public var resolution: ResolutionMode
    public var frameRate: FrameRateMode
    public var hardwareAcceleration: Bool
    /// Explicit constant-quality value in `[0, 1]` (VideoToolbox
    /// `kVTCompressionPropertyKey_Quality`). When set, overrides the `quality`
    /// preset — this is the knob the VMAF-targeted search drives (ADR-0013/0014).
    /// `nil` → derive from `quality`.
    public var constantQuality: Float?

    public init(
        codec: OutputVideoCodec = .hevc,
        quality: QualityPreset = .high,
        resolution: ResolutionMode = .original,
        frameRate: FrameRateMode = .original,
        hardwareAcceleration: Bool = true,
        constantQuality: Float? = nil
    ) {
        self.codec = codec
        self.quality = quality
        self.resolution = resolution
        self.frameRate = frameRate
        self.hardwareAcceleration = hardwareAcceleration
        self.constantQuality = constantQuality
    }
}

public struct AudioEncoderSettings: Sendable {
    public var codec: OutputAudioCodec
    public var bitrate: Int
    public var sampleRate: Int
    public var channels: AudioChannelMode

    public init(
        codec: OutputAudioCodec = .aac,
        bitrate: Int = 256_000,
        sampleRate: Int = 48_000,
        channels: AudioChannelMode = .original
    ) {
        self.codec = codec
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
    }
}
