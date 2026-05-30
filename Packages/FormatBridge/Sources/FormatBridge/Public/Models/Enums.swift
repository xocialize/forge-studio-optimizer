import Foundation

// MARK: - Container Formats

public enum ContainerFormat: String, Codable, Sendable, CaseIterable {
    case mkv
    case webm
    case avi
    case wmv     // WMV/ASF
    case flv
    case ogg     // OGG/OGV
    case vob
    case ts      // MPEG-TS
    case rmvb
    case threeGP = "3gp"
    case mp4
    case mov
    case m4v

    public var isNativeApple: Bool {
        switch self {
        case .mp4, .mov, .m4v: return true
        default: return false
        }
    }
}

// MARK: - Video Codecs

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc       // H.265
    case vp8
    case vp9
    case av1
    case mpeg2
    case mpeg4asp   // DivX/Xvid
    case theora
    case vc1        // VC-1/WMV3
    case prores
    case motionJPEG
    case ffv1
    case unknown

    public var isNativeApple: Bool {
        switch self {
        case .h264, .hevc, .prores: return true
        default: return false
        }
    }
}

// MARK: - Audio Codecs

public enum AudioCodec: String, Codable, Sendable, CaseIterable {
    case aac
    case mp3
    case ac3
    case eac3
    case dts
    case dtsHD
    case vorbis
    case opus
    case wma
    case flac
    case pcm
    case trueHD
    case alac
    case unknown

    public var isNativeApple: Bool {
        switch self {
        case .aac, .alac, .ac3, .eac3, .mp3: return true
        default: return false
        }
    }
}

// MARK: - Output Codecs

public enum OutputVideoCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc
}

public enum OutputAudioCodec: String, Codable, Sendable, CaseIterable {
    case aac
    case alac
    case passthrough
}

// MARK: - Quality & Resolution

public enum QualityPreset: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
    case maximum
}

public enum ResolutionMode: Codable, Sendable, Equatable {
    case original
    case p2160
    case p1080
    case p720
    case p480
    case custom(width: Int, height: Int)
}

public enum FrameRateMode: Codable, Sendable, Equatable {
    case original
    case target(Double)
}

public enum AudioChannelMode: String, Codable, Sendable, CaseIterable {
    case original
    case stereo
    case mono
}

// MARK: - Conversion Tier

public enum ConversionTier: String, Codable, Sendable {
    case nativeFastPath     // MP4/MOV with H.264/HEVC + native audio
    case hybrid             // FFmpeg decode → VideoToolbox encode
    case hybridOptimized    // Hybrid + AI optimization (two-pass)
    case nativeOptimized    // Native input + AI optimization
    case audioOnlyReencode  // Native video, non-native audio
}

// MARK: - Conversion Stage

public enum ConversionStage: String, Codable, Sendable {
    case probing = "Inspecting"
    case analyzing = "Analyzing content"       // Pass 1 (AI)
    case preprocessing = "Optimizing frames"   // Pass 2 (AI + encode)
    case encoding = "Encoding"                 // Direct encode (no AI)
    case finishing = "Finalizing"
}

// MARK: - Optimization Level

public enum OptimizationLevel: String, Codable, Sendable, CaseIterable {
    case off = "Off"
    case light = "Light"
    case balanced = "Balanced"
    case aggressive = "Aggressive"
    case maximum = "Maximum"

    public var enabledProcessors: [ProcessorRole] {
        switch self {
        case .off: return []
        case .light: return [.denoise]
        case .balanced: return [.denoise, .roiSmoothing]
        case .aggressive: return [.denoise, .roiSmoothing, .artifactRemoval]
        case .maximum: return [.denoise, .roiSmoothing, .artifactRemoval, .superResolution]
        }
    }

    public var requiresTwoPass: Bool { self != .off }
}

public enum ProcessorRole: String, Codable, Sendable, CaseIterable {
    case denoise
    case roiSmoothing
    case artifactRemoval
    case superResolution
    case qualityScoring
}

// MARK: - Log Level

public enum LogLevel: Int, Sendable {
    case quiet = -8
    case panic = 0
    case fatal = 8
    case error = 16
    case warning = 24
    case info = 32
    case verbose = 40
    case debug = 48
}

// MARK: - Color Space

public struct ColorSpaceInfo: Codable, Sendable, Equatable {
    public let primaries: String       // "bt709", "bt2020", etc.
    public let transfer: String        // "sdr", "pq", "hlg"
    public let matrix: String          // "bt709", "bt2020nc"

    public init(primaries: String, transfer: String, matrix: String) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
    }
}

public struct HDRMetadata: Codable, Sendable, Equatable {
    public let format: HDRFormat
    public let maxContentLightLevel: Int?
    public let maxFrameAverageLightLevel: Int?

    public init(format: HDRFormat, maxContentLightLevel: Int? = nil, maxFrameAverageLightLevel: Int? = nil) {
        self.format = format
        self.maxContentLightLevel = maxContentLightLevel
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
    }
}

public enum HDRFormat: String, Codable, Sendable {
    case hdr10
    case hdr10Plus
    case dolbyVision
    case hlg
}
