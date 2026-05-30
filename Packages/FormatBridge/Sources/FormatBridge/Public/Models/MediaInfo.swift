import CoreMedia
import Foundation

// MARK: - Media Info (probe result)

public struct MediaInfo: Sendable {
    public let url: URL
    public let container: ContainerFormat
    public let duration: CMTime
    public let fileSize: Int64
    public let videoStreams: [VideoStreamInfo]
    public let audioStreams: [AudioStreamInfo]
    public let subtitleStreams: [SubtitleStreamInfo]
    public let chapters: [Chapter]
    public let metadata: [String: String]
    public let conversionTier: ConversionTier

    public init(
        url: URL,
        container: ContainerFormat,
        duration: CMTime,
        fileSize: Int64,
        videoStreams: [VideoStreamInfo],
        audioStreams: [AudioStreamInfo],
        subtitleStreams: [SubtitleStreamInfo],
        chapters: [Chapter],
        metadata: [String: String],
        conversionTier: ConversionTier
    ) {
        self.url = url
        self.container = container
        self.duration = duration
        self.fileSize = fileSize
        self.videoStreams = videoStreams
        self.audioStreams = audioStreams
        self.subtitleStreams = subtitleStreams
        self.chapters = chapters
        self.metadata = metadata
        self.conversionTier = conversionTier
    }
}

// MARK: - Stream Info

public struct VideoStreamInfo: Sendable {
    public let index: Int
    public let codec: VideoCodec
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let isVFR: Bool
    public let bitDepth: Int
    public let pixelFormat: String
    public let colorSpace: ColorSpaceInfo?
    public let hdrMetadata: HDRMetadata?
    public let bitrate: Int64?
    public let isInterlaced: Bool

    /// Whether the pixel format includes an alpha channel (e.g., yuva420p, bgra).
    public var hasAlpha: Bool {
        let pf = pixelFormat.lowercased()
        return pf.contains("yuva") || pf.contains("rgba") || pf.contains("bgra") || pf.contains("argb")
    }

    public init(
        index: Int,
        codec: VideoCodec,
        width: Int,
        height: Int,
        frameRate: Double,
        isVFR: Bool,
        bitDepth: Int,
        pixelFormat: String,
        colorSpace: ColorSpaceInfo?,
        hdrMetadata: HDRMetadata?,
        bitrate: Int64?,
        isInterlaced: Bool
    ) {
        self.index = index
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.isVFR = isVFR
        self.bitDepth = bitDepth
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
        self.hdrMetadata = hdrMetadata
        self.bitrate = bitrate
        self.isInterlaced = isInterlaced
    }
}

public struct AudioStreamInfo: Sendable {
    public let index: Int
    public let codec: AudioCodec
    public let channels: Int
    public let channelLayout: String
    public let sampleRate: Int
    public let bitrate: Int64?
    public let language: String?
    public let title: String?

    public init(
        index: Int,
        codec: AudioCodec,
        channels: Int,
        channelLayout: String,
        sampleRate: Int,
        bitrate: Int64?,
        language: String?,
        title: String?
    ) {
        self.index = index
        self.codec = codec
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.language = language
        self.title = title
    }
}

public struct SubtitleStreamInfo: Sendable {
    public let index: Int
    public let codec: String       // "srt", "ass", "pgs", "vobsub"
    public let language: String?
    public let title: String?
    public let isForced: Bool

    public init(index: Int, codec: String, language: String?, title: String?, isForced: Bool) {
        self.index = index
        self.codec = codec
        self.language = language
        self.title = title
        self.isForced = isForced
    }
}

public struct Chapter: Sendable {
    public let index: Int
    public let title: String?
    public let startTime: CMTime
    public let endTime: CMTime

    public init(index: Int, title: String?, startTime: CMTime, endTime: CMTime) {
        self.index = index
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
    }
}
