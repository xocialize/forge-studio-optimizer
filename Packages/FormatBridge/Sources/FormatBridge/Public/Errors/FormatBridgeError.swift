import Foundation

public enum FormatBridgeError: LocalizedError, Sendable {
    // Probe errors
    case fileNotFound(URL)
    case unsupportedFormat(String)
    case noVideoStream
    case noAudioStream
    case probeFailed(String)

    // Decode errors
    case decoderNotFound(codec: String)
    case decodeFailed(String)
    case seekFailed(String)
    case invalidStreamIndex(Int)

    // Encode errors
    case encoderConfigurationFailed(String)
    case encoderWriteFailed(String)
    case hardwareEncoderUnavailable
    case invalidOutputPath(URL)

    // Orchestrator errors
    case cancelled
    case outputPathNotWritable(URL)
    case diskSpaceInsufficient(required: Int64, available: Int64)
    case conversionFailed(String)

    // General
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .unsupportedFormat(let format):
            return "Unsupported format: \(format)"
        case .noVideoStream:
            return "No video stream found in the input file"
        case .noAudioStream:
            return "No audio stream found in the input file"
        case .probeFailed(let reason):
            return "Failed to inspect file: \(reason)"
        case .decoderNotFound(let codec):
            return "No decoder available for codec: \(codec)"
        case .decodeFailed(let reason):
            return "Decoding failed: \(reason)"
        case .seekFailed(let reason):
            return "Seek failed: \(reason)"
        case .invalidStreamIndex(let index):
            return "Invalid stream index: \(index)"
        case .encoderConfigurationFailed(let reason):
            return "Encoder configuration failed: \(reason)"
        case .encoderWriteFailed(let reason):
            return "Encoder write failed: \(reason)"
        case .hardwareEncoderUnavailable:
            return "Hardware video encoder is not available"
        case .invalidOutputPath(let url):
            return "Invalid output path: \(url.path)"
        case .cancelled:
            return "Conversion was cancelled"
        case .outputPathNotWritable(let url):
            return "Output path is not writable: \(url.path)"
        case .diskSpaceInsufficient(let required, let available):
            return "Insufficient disk space: \(required / 1_048_576) MB required, \(available / 1_048_576) MB available"
        case .conversionFailed(let reason):
            return "Conversion failed: \(reason)"
        case .notImplemented(let feature):
            return "\(feature) is not yet implemented"
        }
    }
}
