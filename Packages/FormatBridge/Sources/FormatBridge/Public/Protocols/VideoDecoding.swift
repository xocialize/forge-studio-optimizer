import CoreMedia
import CoreVideo
import Foundation

/// Result from interleaved decoding — either a video frame or audio buffer.
public enum DecodedMedia: @unchecked Sendable {
    case video(DecodedVideoFrame)
    case audio(DecodedAudioBuffer)
}

/// Demuxes containers and decodes video/audio to raw frames.
public protocol VideoDecoding: AnyObject, Sendable {
    func open(url: URL) async throws
    func selectStreams(video: Int, audio: Int) throws

    /// Decode the next video frame (skips non-video packets).
    func decodeNextVideoFrame() async throws -> DecodedVideoFrame?

    /// Decode the next audio buffer (skips non-audio packets).
    func decodeNextAudioBuffer() async throws -> DecodedAudioBuffer?

    /// Decode the next available media — returns whichever stream the demuxer produces next.
    /// This preserves interleaved packet order, critical for AVAssetWriter which requires
    /// monotonically increasing timestamps per input.
    func decodeNext() async throws -> DecodedMedia?

    func seek(to time: CMTime) async throws
    func close()
    var videoTimeBase: CMTime { get }
    var audioTimeBase: CMTime { get }
}
