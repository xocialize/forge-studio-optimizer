import CoreMedia
import Foundation

/// Maps FFmpeg AVRational timebases to CMTime.
///
/// FFmpeg uses rational timebases per stream (e.g., 1/90000 for MPEG-TS, 1/1000 for MKV).
/// AVAssetWriter uses CMTime. This mapper rescales to a consistent output timebase
/// (default 600, which supports 24/25/30/60 fps cleanly) to avoid precision loss.
struct TimestampMapper {
    /// Default output timescale — 600 supports common frame rates without precision loss.
    static let defaultTimescale: Int32 = 600

    /// Converts an FFmpeg PTS (presentation timestamp) to CMTime.
    /// - Parameters:
    ///   - pts: The FFmpeg presentation timestamp value
    ///   - timebaseNum: The timebase numerator (e.g., 1)
    ///   - timebaseDen: The timebase denominator (e.g., 90000)
    ///   - outputTimescale: The target CMTime timescale
    /// - Returns: A CMTime representing the same point in time
    static func cmTime(
        fromPTS pts: Int64,
        timebaseNum: Int32,
        timebaseDen: Int32,
        outputTimescale: Int32 = defaultTimescale
    ) -> CMTime {
        guard timebaseDen != 0 else { return .zero }

        // Equivalent to av_rescale_q: pts * timebaseNum / timebaseDen * outputTimescale
        let seconds = Double(pts) * Double(timebaseNum) / Double(timebaseDen)
        return CMTimeMakeWithSeconds(seconds, preferredTimescale: outputTimescale)
    }

    /// Computes frame duration from FFmpeg packet duration.
    static func duration(
        fromPacketDuration pktDuration: Int64,
        timebaseNum: Int32,
        timebaseDen: Int32,
        outputTimescale: Int32 = defaultTimescale
    ) -> CMTime {
        cmTime(fromPTS: pktDuration, timebaseNum: timebaseNum, timebaseDen: timebaseDen, outputTimescale: outputTimescale)
    }
}
