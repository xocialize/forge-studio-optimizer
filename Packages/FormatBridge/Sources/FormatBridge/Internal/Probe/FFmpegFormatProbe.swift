import CoreMedia
import FFmpegXC
import Foundation

final class FFmpegFormatProbe: MediaProbing, @unchecked Sendable {

    func probe(url: URL) async throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FormatBridgeError.fileNotFound(url)
        }

        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        let path = url.path

        var ret = avformat_open_input(&fmtCtx, path, nil, nil)
        guard ret == 0, let ctx = fmtCtx else {
            throw FormatBridgeError.probeFailed("avformat_open_input failed: \(avErrorString(ret))")
        }
        defer { avformat_close_input(&fmtCtx) }

        ret = avformat_find_stream_info(ctx, nil)
        guard ret >= 0 else {
            throw FormatBridgeError.probeFailed("avformat_find_stream_info failed: \(avErrorString(ret))")
        }

        let container = detectContainer(ctx)
        let duration = extractDuration(ctx)
        let fileSize = fileSize(at: url)

        var videoStreams: [VideoStreamInfo] = []
        var audioStreams: [AudioStreamInfo] = []
        var subtitleStreams: [SubtitleStreamInfo] = []

        for i in 0..<Int(ctx.pointee.nb_streams) {
            let stream = ctx.pointee.streams[i]!
            let codecpar = stream.pointee.codecpar!

            switch codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                videoStreams.append(extractVideoStream(stream: stream, index: i))
            case AVMEDIA_TYPE_AUDIO:
                audioStreams.append(extractAudioStream(stream: stream, index: i))
            case AVMEDIA_TYPE_SUBTITLE:
                subtitleStreams.append(extractSubtitleStream(stream: stream, index: i))
            default:
                break
            }
        }

        let chapters = extractChapters(ctx)
        let metadata = extractMetadata(ctx.pointee.metadata)

        let tier = TierRouter.determineTier(
            container: container,
            videoCodec: videoStreams.first?.codec,
            audioCodec: audioStreams.first?.codec,
            optimizationEnabled: false
        )

        return MediaInfo(
            url: url,
            container: container,
            duration: duration,
            fileSize: fileSize,
            videoStreams: videoStreams,
            audioStreams: audioStreams,
            subtitleStreams: subtitleStreams,
            chapters: chapters,
            metadata: metadata,
            conversionTier: tier
        )
    }

    // MARK: - Container Detection

    private func detectContainer(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> ContainerFormat {
        guard let iformat = ctx.pointee.iformat else { return .mp4 }
        let name = String(cString: iformat.pointee.name)

        switch name {
        case "matroska,webm":
            // Distinguish MKV from WebM by checking codecs
            if let stream = findFirstVideoStream(ctx),
               let codecpar = stream.pointee.codecpar {
                let codecId = codecpar.pointee.codec_id
                if codecId == AV_CODEC_ID_VP8 || codecId == AV_CODEC_ID_VP9 {
                    return .webm
                }
            }
            return .mkv
        case "avi": return .avi
        case "asf": return .wmv
        case "flv": return .flv
        case "ogg": return .ogg
        case "mpeg": return .vob
        case "mpegts": return .ts
        case "mov,mp4,m4a,3gp,3g2,mj2":
            let filename = String(cString: ctx.pointee.url)
            if filename.hasSuffix(".mov") { return .mov }
            if filename.hasSuffix(".m4v") { return .m4v }
            return .mp4
        case "rm", "rmvb": return .rmvb
        case "3gp": return .threeGP
        default: return .mp4
        }
    }

    // MARK: - Video Stream Extraction

    private func extractVideoStream(stream: UnsafeMutablePointer<AVStream>, index: Int) -> VideoStreamInfo {
        let codecpar = stream.pointee.codecpar!
        let codec = mapVideoCodec(codecpar.pointee.codec_id)

        let tb = stream.pointee.avg_frame_rate
        let frameRate: Double = tb.den > 0 ? Double(tb.num) / Double(tb.den) : 0

        let rTb = stream.pointee.r_frame_rate
        let isVFR = (tb.num != rTb.num || tb.den != rTb.den) && tb.num > 0 && rTb.num > 0

        let bitDepth: Int
        switch codecpar.pointee.format {
        case AV_PIX_FMT_YUV420P10LE.rawValue, AV_PIX_FMT_YUV420P10BE.rawValue,
             AV_PIX_FMT_YUV422P10LE.rawValue, AV_PIX_FMT_YUV444P10LE.rawValue:
            bitDepth = 10
        case AV_PIX_FMT_YUV420P12LE.rawValue, AV_PIX_FMT_YUV422P12LE.rawValue:
            bitDepth = 12
        default:
            bitDepth = 8
        }

        let pixFmt: String
        if codecpar.pointee.format >= 0 {
            if let name = av_get_pix_fmt_name(AVPixelFormat(rawValue: codecpar.pointee.format)) {
                pixFmt = String(cString: name)
            } else {
                pixFmt = "unknown"
            }
        } else {
            pixFmt = "unknown"
        }

        let colorSpace = extractColorSpace(codecpar)
        let hdr = extractHDRMetadata(codecpar, colorSpace: colorSpace)

        let fieldOrder = codecpar.pointee.field_order
        let isInterlaced = fieldOrder != AV_FIELD_PROGRESSIVE && fieldOrder != AV_FIELD_UNKNOWN

        return VideoStreamInfo(
            index: index,
            codec: codec,
            width: Int(codecpar.pointee.width),
            height: Int(codecpar.pointee.height),
            frameRate: frameRate,
            isVFR: isVFR,
            bitDepth: bitDepth,
            pixelFormat: pixFmt,
            colorSpace: colorSpace,
            hdrMetadata: hdr,
            bitrate: codecpar.pointee.bit_rate > 0 ? codecpar.pointee.bit_rate : nil,
            isInterlaced: isInterlaced
        )
    }

    // MARK: - Audio Stream Extraction

    private func extractAudioStream(stream: UnsafeMutablePointer<AVStream>, index: Int) -> AudioStreamInfo {
        let codecpar = stream.pointee.codecpar!
        let codec = mapAudioCodec(codecpar.pointee.codec_id)

        var channelLayout = "unknown"
        let chCount = Int(codecpar.pointee.ch_layout.nb_channels)

        switch chCount {
        case 1: channelLayout = "mono"
        case 2: channelLayout = "stereo"
        case 6: channelLayout = "5.1"
        case 8: channelLayout = "7.1"
        default: channelLayout = "\(chCount)ch"
        }

        let language = extractLanguageTag(stream.pointee.metadata)
        let title = extractDictValue(stream.pointee.metadata, key: "title")

        return AudioStreamInfo(
            index: index,
            codec: codec,
            channels: chCount,
            channelLayout: channelLayout,
            sampleRate: Int(codecpar.pointee.sample_rate),
            bitrate: codecpar.pointee.bit_rate > 0 ? codecpar.pointee.bit_rate : nil,
            language: language,
            title: title
        )
    }

    // MARK: - Subtitle Stream Extraction

    private func extractSubtitleStream(stream: UnsafeMutablePointer<AVStream>, index: Int) -> SubtitleStreamInfo {
        let codecpar = stream.pointee.codecpar!

        let codecName: String
        if let desc = avcodec_descriptor_get(codecpar.pointee.codec_id) {
            codecName = String(cString: desc.pointee.name)
        } else {
            codecName = "unknown"
        }

        let language = extractLanguageTag(stream.pointee.metadata)
        let title = extractDictValue(stream.pointee.metadata, key: "title")

        let disposition = stream.pointee.disposition
        let isForced = (disposition & AV_DISPOSITION_FORCED) != 0

        return SubtitleStreamInfo(
            index: index,
            codec: codecName,
            language: language,
            title: title,
            isForced: isForced
        )
    }

    // MARK: - Chapters

    private func extractChapters(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> [Chapter] {
        var chapters: [Chapter] = []
        for i in 0..<Int(ctx.pointee.nb_chapters) {
            guard let ch = ctx.pointee.chapters[i] else { continue }
            let tb = ch.pointee.time_base
            let startSec = Double(ch.pointee.start) * Double(tb.num) / Double(tb.den)
            let endSec = Double(ch.pointee.end) * Double(tb.num) / Double(tb.den)
            let title = extractDictValue(ch.pointee.metadata, key: "title")

            chapters.append(Chapter(
                index: i,
                title: title,
                startTime: CMTimeMakeWithSeconds(startSec, preferredTimescale: 600),
                endTime: CMTimeMakeWithSeconds(endSec, preferredTimescale: 600)
            ))
        }
        return chapters
    }

    // MARK: - Metadata

    private func extractMetadata(_ dict: OpaquePointer?) -> [String: String] {
        guard let dict else { return [:] }
        var result: [String: String] = [:]
        var tag: UnsafeMutablePointer<AVDictionaryEntry>?

        while true {
            tag = av_dict_get(dict, "", tag, AV_DICT_IGNORE_SUFFIX)
            guard let entry = tag else { break }
            let key = String(cString: entry.pointee.key)
            let value = String(cString: entry.pointee.value)
            result[key] = value
        }
        return result
    }

    private func extractDictValue(_ dict: OpaquePointer?, key: String) -> String? {
        guard let dict else { return nil }
        guard let entry = av_dict_get(dict, key, nil, 0) else { return nil }
        return String(cString: entry.pointee.value)
    }

    private func extractLanguageTag(_ dict: OpaquePointer?) -> String? {
        extractDictValue(dict, key: "language")
    }

    // MARK: - Color Space / HDR

    private func extractColorSpace(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> ColorSpaceInfo? {
        let primaries = codecpar.pointee.color_primaries
        let transfer = codecpar.pointee.color_trc
        let matrix = codecpar.pointee.color_space

        guard primaries != AVCOL_PRI_UNSPECIFIED || transfer != AVCOL_TRC_UNSPECIFIED else {
            return nil
        }

        return ColorSpaceInfo(
            primaries: colorPrimariesString(primaries),
            transfer: colorTransferString(transfer),
            matrix: colorMatrixString(matrix)
        )
    }

    private func extractHDRMetadata(_ codecpar: UnsafeMutablePointer<AVCodecParameters>, colorSpace: ColorSpaceInfo?) -> HDRMetadata? {
        guard let cs = colorSpace else { return nil }

        let format: HDRFormat?
        switch cs.transfer {
        case "pq", "smpte2084":
            format = .hdr10
        case "hlg", "arib-std-b67":
            format = .hlg
        default:
            format = nil
        }

        guard let fmt = format else { return nil }
        return HDRMetadata(format: fmt)
    }

    // MARK: - Codec Mapping

    private func mapVideoCodec(_ codecId: AVCodecID) -> VideoCodec {
        switch codecId {
        case AV_CODEC_ID_H264: return .h264
        case AV_CODEC_ID_HEVC: return .hevc
        case AV_CODEC_ID_VP8: return .vp8
        case AV_CODEC_ID_VP9: return .vp9
        case AV_CODEC_ID_AV1: return .av1
        case AV_CODEC_ID_MPEG2VIDEO: return .mpeg2
        case AV_CODEC_ID_MPEG4: return .mpeg4asp
        case AV_CODEC_ID_THEORA: return .theora
        case AV_CODEC_ID_VC1, AV_CODEC_ID_WMV3: return .vc1
        case AV_CODEC_ID_PRORES: return .prores
        case AV_CODEC_ID_MJPEG: return .motionJPEG
        case AV_CODEC_ID_FFV1: return .ffv1
        default: return .unknown
        }
    }

    private func mapAudioCodec(_ codecId: AVCodecID) -> AudioCodec {
        switch codecId {
        case AV_CODEC_ID_AAC: return .aac
        case AV_CODEC_ID_MP3: return .mp3
        case AV_CODEC_ID_AC3: return .ac3
        case AV_CODEC_ID_EAC3: return .eac3
        case AV_CODEC_ID_DTS: return .dts
        case AV_CODEC_ID_VORBIS: return .vorbis
        case AV_CODEC_ID_OPUS: return .opus
        case AV_CODEC_ID_WMAV1, AV_CODEC_ID_WMAV2, AV_CODEC_ID_WMAPRO: return .wma
        case AV_CODEC_ID_FLAC: return .flac
        case AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S24LE, AV_CODEC_ID_PCM_S32LE,
             AV_CODEC_ID_PCM_F32LE, AV_CODEC_ID_PCM_F64LE: return .pcm
        case AV_CODEC_ID_TRUEHD: return .trueHD
        case AV_CODEC_ID_ALAC: return .alac
        default: return .unknown
        }
    }

    // MARK: - Helpers

    private func findFirstVideoStream(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> UnsafeMutablePointer<AVStream>? {
        for i in 0..<Int(ctx.pointee.nb_streams) {
            let stream = ctx.pointee.streams[i]!
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                return stream
            }
        }
        return nil
    }

    private static let avNoPTSValue: Int64 = Int64(bitPattern: 0x8000000000000000)
    private static let avTimeBase: Int64 = 1_000_000

    private func extractDuration(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> CMTime {
        guard ctx.pointee.duration != Self.avNoPTSValue else { return .indefinite }
        let seconds = Double(ctx.pointee.duration) / Double(Self.avTimeBase)
        return CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func colorPrimariesString(_ p: AVColorPrimaries) -> String {
        switch p {
        case AVCOL_PRI_BT709: return "bt709"
        case AVCOL_PRI_BT2020: return "bt2020"
        case AVCOL_PRI_SMPTE432: return "display-p3"
        default: return "unknown"
        }
    }

    private func colorTransferString(_ t: AVColorTransferCharacteristic) -> String {
        switch t {
        case AVCOL_TRC_BT709: return "bt709"
        case AVCOL_TRC_SMPTE2084: return "pq"
        case AVCOL_TRC_ARIB_STD_B67: return "hlg"
        case AVCOL_TRC_LINEAR: return "linear"
        default: return "sdr"
        }
    }

    private func colorMatrixString(_ m: AVColorSpace) -> String {
        switch m {
        case AVCOL_SPC_BT709: return "bt709"
        case AVCOL_SPC_BT2020_NCL: return "bt2020nc"
        case AVCOL_SPC_BT2020_CL: return "bt2020cl"
        default: return "unknown"
        }
    }
}

// MARK: - FFmpeg Error String Helper

func avErrorString(_ errnum: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 128)
    av_strerror(errnum, &buf, 128)
    return String(cString: buf)
}
