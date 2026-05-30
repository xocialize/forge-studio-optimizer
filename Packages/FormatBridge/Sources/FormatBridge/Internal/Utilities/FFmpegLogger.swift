import FFmpegXC
import Foundation
import os.log

enum FFmpegLogger {
    private static let logger = Logger(subsystem: "com.mvscollective.FormatBridge", category: "FFmpeg")
    nonisolated(unsafe) private(set) static var currentLevel: LogLevel = .warning

    static func configure(level: LogLevel) {
        currentLevel = level
        av_log_set_level(level.avLogLevel)
        av_log_set_callback { _, avLevel, fmt, args in
            guard avLevel <= FFmpegLogger.currentLevel.avLogLevel else { return }
            guard let fmt else { return }

            // Format the FFmpeg log message
            var buf = [CChar](repeating: 0, count: 1024)
            vsnprintf(&buf, 1024, fmt, args!)
            let message = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }

            switch avLevel {
            case 0...8:   FFmpegLogger.logger.critical("\(message, privacy: .public)")
            case 9...16:  FFmpegLogger.logger.error("\(message, privacy: .public)")
            case 17...24: FFmpegLogger.logger.warning("\(message, privacy: .public)")
            case 25...32: FFmpegLogger.logger.info("\(message, privacy: .public)")
            default:      FFmpegLogger.logger.debug("\(message, privacy: .public)")
            }
        }
    }
}

extension LogLevel {
    var avLogLevel: Int32 {
        Int32(self.rawValue)
    }
}
