import CoreMedia

extension CMTime {
    /// Creates a CMTime from an FFmpeg PTS value and timebase.
    /// - Parameters:
    ///   - pts: FFmpeg presentation timestamp
    ///   - timebaseNum: Timebase numerator (e.g., 1)
    ///   - timebaseDen: Timebase denominator (e.g., 90000 for MPEG-TS, 1000 for MKV)
    init(pts: Int64, timebaseNum: Int32, timebaseDen: Int32) {
        self = TimestampMapper.cmTime(
            fromPTS: pts,
            timebaseNum: timebaseNum,
            timebaseDen: timebaseDen
        )
    }
}
