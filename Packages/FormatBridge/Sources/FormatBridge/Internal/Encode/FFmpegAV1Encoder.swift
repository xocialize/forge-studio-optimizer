import FFmpegXC
import Foundation

// AVERROR(EAGAIN) / AVERROR_EOF — the libav* sentinel returns (no Swift macro import).
private let avErrEAGAIN: Int32 = -35   // -EAGAIN on Darwin
private let avErrEOF: Int32 = {
    let e = Int32(bitPattern: UInt32(UInt8(ascii: "E")) | (UInt32(UInt8(ascii: "O")) << 8)
                  | (UInt32(UInt8(ascii: "F")) << 16) | (UInt32(UInt8(ascii: " ")) << 24))
    return -e
}()

/// In-process AV1 encode (#58, ADR-0017 Phase B) — the self-contained replacement for the
/// `ffmpeg -c:v libsvtav1` subprocess. Decodes a source, converts to yuv420p, and re-encodes
/// to AV1/MP4 with SVT-AV1 (now compiled into FFmpegXC), tagging BT.709. Same knobs as the
/// subprocess path: CRF (0…63), SVT-AV1 preset (0 slow…13 fast), optional film-grain
/// synthesis, and an optional frame cap for the CRF-search probes.
///
/// Video-only by design (`-an`) — the AV1 tier targets VMAF/quality on the video. Pure
/// libav*; no external ffmpeg binary.
public enum FFmpegAV1Encoder {

    public struct Settings: Sendable {
        public var crf: Int
        public var preset: Int
        public var filmGrain: Int?
        public var maxFrames: Int?          // nil = whole clip; N = first N frames (probe)
        public init(crf: Int, preset: Int = 6, filmGrain: Int? = nil, maxFrames: Int? = nil) {
            self.crf = crf; self.preset = preset; self.filmGrain = filmGrain; self.maxFrames = maxFrames
        }
    }

    public enum AV1Error: Error, CustomStringConvertible {
        case fail(String)
        public var description: String { switch self { case .fail(let s): return "AV1 encode: \(s)" } }
    }

    /// Transcode `source` → AV1/MP4 at `output`. Throws on any libav* failure.
    public static func encode(source: URL, output: URL, settings: Settings) throws {
        try? FileManager.default.removeItem(at: output)

        // ---- input + decoder -------------------------------------------------
        var ifmt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ifmt, source.path, nil, nil) == 0, let inFmt = ifmt else {
            throw AV1Error.fail("avformat_open_input(\(source.lastPathComponent))")
        }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = inFmt; avformat_close_input(&p) }
        guard avformat_find_stream_info(inFmt, nil) >= 0 else { throw AV1Error.fail("find_stream_info") }

        let vIdx = av_find_best_stream(inFmt, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard vIdx >= 0, let vStream = inFmt.pointee.streams[Int(vIdx)] else { throw AV1Error.fail("no video stream") }
        let codecpar = vStream.pointee.codecpar!
        guard let dec = avcodec_find_decoder(codecpar.pointee.codec_id),
              let decCtx = avcodec_alloc_context3(dec) else { throw AV1Error.fail("alloc decoder") }
        var decCtxOpt: UnsafeMutablePointer<AVCodecContext>? = decCtx
        defer { avcodec_free_context(&decCtxOpt) }
        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0,
              avcodec_open2(decCtx, dec, nil) == 0 else { throw AV1Error.fail("open decoder") }

        let width = decCtx.pointee.width, height = decCtx.pointee.height
        var fps = av_guess_frame_rate(inFmt, vStream, nil)
        if fps.num <= 0 || fps.den <= 0 { fps = AVRational(num: 30, den: 1) }

        // ---- SVT-AV1 encoder -------------------------------------------------
        guard let enc = avcodec_find_encoder_by_name("libsvtav1"),
              let encCtx = avcodec_alloc_context3(enc) else { throw AV1Error.fail("libsvtav1 not available") }
        var encCtxOpt: UnsafeMutablePointer<AVCodecContext>? = encCtx
        defer { avcodec_free_context(&encCtxOpt) }
        encCtx.pointee.width = width
        encCtx.pointee.height = height
        encCtx.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        encCtx.pointee.time_base = AVRational(num: fps.den, den: fps.num)   // 1/fps; pts = frame counter
        encCtx.pointee.framerate = fps
        // Tag BT.709 (never ship untagged — the colour-correctness lesson).
        encCtx.pointee.color_primaries = AVCOL_PRI_BT709
        encCtx.pointee.color_trc = AVCOL_TRC_BT709
        encCtx.pointee.colorspace = AVCOL_SPC_BT709
        encCtx.pointee.color_range = AVCOL_RANGE_MPEG

        av_opt_set(encCtx.pointee.priv_data, "crf", "\(settings.crf)", 0)
        av_opt_set(encCtx.pointee.priv_data, "preset", "\(settings.preset)", 0)
        if let g = settings.filmGrain, g > 0 {
            av_opt_set(encCtx.pointee.priv_data, "svtav1-params", "film-grain=\(g):film-grain-denoise=1", 0)
        }

        // ---- output (mp4) ----------------------------------------------------
        var ofmt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&ofmt, nil, "mp4", output.path) >= 0, let outFmt = ofmt else {
            throw AV1Error.fail("alloc_output_context2")
        }
        defer {
            if outFmt.pointee.pb != nil { avio_closep(&outFmt.pointee.pb) }
            avformat_free_context(outFmt)
        }
        if (Int32(outFmt.pointee.oformat.pointee.flags) & AVFMT_GLOBALHEADER) != 0 {
            encCtx.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }
        guard avcodec_open2(encCtx, enc, nil) == 0 else { throw AV1Error.fail("open libsvtav1") }
        guard let outStream = avformat_new_stream(outFmt, nil) else { throw AV1Error.fail("new_stream") }
        guard avcodec_parameters_from_context(outStream.pointee.codecpar, encCtx) >= 0 else {
            throw AV1Error.fail("parameters_from_context")
        }
        outStream.pointee.time_base = encCtx.pointee.time_base
        guard avio_open(&outFmt.pointee.pb, output.path, AVIO_FLAG_WRITE) >= 0 else { throw AV1Error.fail("avio_open") }
        guard avformat_write_header(outFmt, nil) >= 0 else { throw AV1Error.fail("write_header") }

        // ---- sws (source pix_fmt → yuv420p) ---------------------------------
        guard let sws = sws_getContext(width, height, decCtx.pointee.pix_fmt,
                                       width, height, AV_PIX_FMT_YUV420P,
                                       SWS_BILINEAR, nil, nil, nil) else { throw AV1Error.fail("sws_getContext") }
        defer { sws_freeContext(sws) }

        let pkt = av_packet_alloc(), frame = av_frame_alloc(), yuv = av_frame_alloc(), encPkt = av_packet_alloc()
        defer {
            var a: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&a)
            var b: UnsafeMutablePointer<AVPacket>? = encPkt; av_packet_free(&b)
            var c: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&c)
            var d: UnsafeMutablePointer<AVFrame>? = yuv; av_frame_free(&d)
        }
        yuv!.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        yuv!.pointee.width = width
        yuv!.pointee.height = height
        guard av_frame_get_buffer(yuv, 32) >= 0 else { throw AV1Error.fail("frame_get_buffer") }

        var nextPTS: Int64 = 0
        let cap = settings.maxFrames

        func writeEncoded() throws {
            while true {
                let r = avcodec_receive_packet(encCtx, encPkt)
                if r == avErrEAGAIN || r == avErrEOF { break }
                guard r >= 0 else { throw AV1Error.fail("receive_packet \(r)") }
                av_packet_rescale_ts(encPkt, encCtx.pointee.time_base, outStream.pointee.time_base)
                encPkt!.pointee.stream_index = outStream.pointee.index
                _ = av_interleaved_write_frame(outFmt, encPkt)
                av_packet_unref(encPkt)
            }
        }
        func encode(_ f: UnsafeMutablePointer<AVFrame>?) throws {
            guard avcodec_send_frame(encCtx, f) >= 0 else { throw AV1Error.fail("send_frame") }
            try writeEncoded()
        }
        // sws_scale src(decoded frame) → dst(yuv), using the decoder's plane-array pattern.
        func scaleAndEncode() throws {
            guard av_frame_make_writable(yuv) >= 0 else { throw AV1Error.fail("make_writable") }
            let sd = frame!.pointee.data, sl = frame!.pointee.linesize
            var srcData: [UnsafePointer<UInt8>?] = [UnsafePointer(sd.0), UnsafePointer(sd.1), UnsafePointer(sd.2), UnsafePointer(sd.3)]
            var srcLines: [Int32] = [sl.0, sl.1, sl.2, sl.3]
            let dd = yuv!.pointee.data, dl = yuv!.pointee.linesize
            var dstData: [UnsafeMutablePointer<UInt8>?] = [dd.0, dd.1, dd.2, dd.3]
            var dstLines: [Int32] = [dl.0, dl.1, dl.2, dl.3]
            sws_scale(sws, &srcData, &srcLines, 0, height, &dstData, &dstLines)
            yuv!.pointee.pts = nextPTS; nextPTS += 1
            try encode(yuv)
        }

        // ---- decode → convert → encode loop ---------------------------------
        decodeLoop: while av_read_frame(inFmt, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt!.pointee.stream_index == vIdx else { continue }
            guard avcodec_send_packet(decCtx, pkt) >= 0 else { continue }
            while true {
                let r = avcodec_receive_frame(decCtx, frame)
                if r == avErrEAGAIN || r == avErrEOF { break }
                guard r >= 0 else { throw AV1Error.fail("receive_frame \(r)") }
                if let cap, nextPTS >= Int64(cap) { av_frame_unref(frame); break decodeLoop }
                try scaleAndEncode()
                av_frame_unref(frame)
            }
        }
        // Flush decoder → encoder.
        _ = avcodec_send_packet(decCtx, nil)
        while avcodec_receive_frame(decCtx, frame) >= 0 {
            if let cap, nextPTS >= Int64(cap) { av_frame_unref(frame); break }
            try scaleAndEncode()
            av_frame_unref(frame)
        }
        try encode(nil)
        av_write_trailer(outFmt)

        guard FileManager.default.fileExists(atPath: output.path), nextPTS > 0 else {
            throw AV1Error.fail("no frames encoded")
        }
    }
}
