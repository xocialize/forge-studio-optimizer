import Foundation

public struct VideoEncoderSettings: Sendable {
    public var codec: OutputVideoCodec
    public var quality: QualityPreset
    public var resolution: ResolutionMode
    public var frameRate: FrameRateMode
    public var hardwareAcceleration: Bool

    public init(
        codec: OutputVideoCodec = .hevc,
        quality: QualityPreset = .high,
        resolution: ResolutionMode = .original,
        frameRate: FrameRateMode = .original,
        hardwareAcceleration: Bool = true
    ) {
        self.codec = codec
        self.quality = quality
        self.resolution = resolution
        self.frameRate = frameRate
        self.hardwareAcceleration = hardwareAcceleration
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
