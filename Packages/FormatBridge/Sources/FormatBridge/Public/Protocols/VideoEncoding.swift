import CoreMedia
import CoreVideo
import Foundation

/// Encodes raw frames to H.264/HEVC via hardware and muxes to MP4.
public protocol VideoEncoding: AnyObject, Sendable {
    /// Configure the encoder for an output file.
    ///
    /// Pass `nil` for `audioSettings` to produce a video-only file. The encoder
    /// then skips configuring an audio input on the underlying `AVAssetWriter`,
    /// which is required when the source has no audio stream — otherwise the
    /// writer stalls waiting on audio data that never arrives.
    func configure(output: URL, videoSettings: VideoEncoderSettings, audioSettings: AudioEncoderSettings?) throws
    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime, duration: CMTime) throws
    /// Append decoded audio samples. Throws if the encoder was configured
    /// with `audioSettings: nil` (i.e., video-only mode).
    func appendAudioSamples(_ sampleBuffer: CMSampleBuffer) throws
    func finish() async throws
    var isHardwareAccelerated: Bool { get }
}
