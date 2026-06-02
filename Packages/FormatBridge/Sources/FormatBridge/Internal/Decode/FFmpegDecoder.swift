import CoreMedia
import CoreVideo
import FFmpegXC
import Foundation

/// Actor-isolated FFmpeg decoder. All FFmpeg C API calls are serialized here.
/// Decodes video frames to CVPixelBuffer and audio to CMSampleBuffer.
final class FFmpegDecoderImpl: VideoDecoding, @unchecked Sendable {

    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var videoCodecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var audioCodecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swsCtx: OpaquePointer?

    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1

    private let pixelBufferConverter = PixelBufferConverter()

    private(set) var videoTimeBase: CMTime = .zero
    private(set) var audioTimeBase: CMTime = .zero

    private var videoTBNum: Int32 = 0
    private var videoTBDen: Int32 = 1
    private var audioTBNum: Int32 = 0
    private var audioTBDen: Int32 = 1

    // Reusable packet and frame
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?

    private var isOpen = false

    func open(url: URL) async throws {
        guard !isOpen else { return }

        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        var ret = avformat_open_input(&fmtCtx, url.path, nil, nil)
        guard ret == 0, let ctx = fmtCtx else {
            throw FormatBridgeError.decodeFailed("avformat_open_input failed: \(avErrorString(ret))")
        }
        formatCtx = ctx

        ret = avformat_find_stream_info(ctx, nil)
        guard ret >= 0 else {
            throw FormatBridgeError.decodeFailed("avformat_find_stream_info failed: \(avErrorString(ret))")
        }

        // Find best video and audio streams
        let vidIdx = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        let audIdx = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)

        if vidIdx >= 0 {
            videoStreamIndex = vidIdx
        }
        if audIdx >= 0 {
            audioStreamIndex = audIdx
        }

        // Open video decoder
        if videoStreamIndex >= 0 {
            try openDecoder(streamIndex: videoStreamIndex, codecCtx: &videoCodecCtx)
            let tb = ctx.pointee.streams[Int(videoStreamIndex)]!.pointee.time_base
            videoTBNum = tb.num
            videoTBDen = tb.den
            videoTimeBase = CMTimeMake(value: Int64(tb.num), timescale: tb.den)
        }

        // Open audio decoder
        if audioStreamIndex >= 0 {
            try openDecoder(streamIndex: audioStreamIndex, codecCtx: &audioCodecCtx)
            let tb = ctx.pointee.streams[Int(audioStreamIndex)]!.pointee.time_base
            audioTBNum = tb.num
            audioTBDen = tb.den
            audioTimeBase = CMTimeMake(value: Int64(tb.num), timescale: tb.den)
        }

        packet = av_packet_alloc()
        frame = av_frame_alloc()
        isOpen = true
    }

    func selectStreams(video: Int, audio: Int) throws {
        guard let ctx = formatCtx else {
            throw FormatBridgeError.decodeFailed("Not open")
        }

        if video >= 0 && video < Int(ctx.pointee.nb_streams) {
            // Close old video decoder if different
            if videoStreamIndex >= 0 && videoStreamIndex != Int32(video) {
                avcodec_free_context(&videoCodecCtx)
            }
            videoStreamIndex = Int32(video)
            try openDecoder(streamIndex: videoStreamIndex, codecCtx: &videoCodecCtx)
            let tb = ctx.pointee.streams[video]!.pointee.time_base
            videoTBNum = tb.num
            videoTBDen = tb.den
        }

        if audio >= 0 && audio < Int(ctx.pointee.nb_streams) {
            if audioStreamIndex >= 0 && audioStreamIndex != Int32(audio) {
                avcodec_free_context(&audioCodecCtx)
            }
            audioStreamIndex = Int32(audio)
            try openDecoder(streamIndex: audioStreamIndex, codecCtx: &audioCodecCtx)
            let tb = ctx.pointee.streams[audio]!.pointee.time_base
            audioTBNum = tb.num
            audioTBDen = tb.den
        }
    }

    func decodeNextVideoFrame() async throws -> DecodedVideoFrame? {
        guard let ctx = formatCtx, let pkt = packet, let frm = frame else {
            throw FormatBridgeError.decodeFailed("Decoder not open")
        }

        while true {
            let ret = av_read_frame(ctx, pkt)
            if ret < 0 {
                if ret == averrorEOF { return nil }
                throw FormatBridgeError.decodeFailed("av_read_frame failed: \(avErrorString(ret))")
            }
            defer { av_packet_unref(pkt) }

            if pkt.pointee.stream_index == videoStreamIndex {
                if let decoded = try decodeVideoPacket(pkt, frame: frm) {
                    return decoded
                }
                // Decoder needs more data, continue reading
            }
            // Skip non-video packets
        }
    }

    func decodeNextAudioBuffer() async throws -> DecodedAudioBuffer? {
        guard let ctx = formatCtx, let pkt = packet, let frm = frame else {
            throw FormatBridgeError.decodeFailed("Decoder not open")
        }

        while true {
            let ret = av_read_frame(ctx, pkt)
            if ret < 0 {
                if ret == averrorEOF { return nil }
                throw FormatBridgeError.decodeFailed("av_read_frame failed: \(avErrorString(ret))")
            }
            defer { av_packet_unref(pkt) }

            if pkt.pointee.stream_index == audioStreamIndex {
                if let decoded = try decodeAudioPacket(pkt, frame: frm) {
                    return decoded
                }
            }
        }
    }

    func decodeNext() async throws -> DecodedMedia? {
        guard let ctx = formatCtx, let pkt = packet, let frm = frame else {
            throw FormatBridgeError.decodeFailed("Decoder not open")
        }

        while true {
            let ret = av_read_frame(ctx, pkt)
            if ret < 0 {
                if ret == averrorEOF { return nil }
                throw FormatBridgeError.decodeFailed("av_read_frame failed: \(avErrorString(ret))")
            }
            defer { av_packet_unref(pkt) }

            if pkt.pointee.stream_index == videoStreamIndex {
                if let decoded = try decodeVideoPacket(pkt, frame: frm) {
                    return .video(decoded)
                }
            } else if pkt.pointee.stream_index == audioStreamIndex {
                if let decoded = try decodeAudioPacket(pkt, frame: frm) {
                    return .audio(decoded)
                }
            }
            // Skip other stream types, or decoder needs more data — continue
        }
    }

    func seek(to time: CMTime) async throws {
        guard let ctx = formatCtx else {
            throw FormatBridgeError.seekFailed("Decoder not open")
        }

        let seconds = CMTimeGetSeconds(time)
        let timestamp = Int64(seconds * Double(Self.avTimeBase))

        let ret = av_seek_frame(ctx, -1, timestamp, AVSEEK_FLAG_BACKWARD)
        guard ret >= 0 else {
            throw FormatBridgeError.seekFailed("av_seek_frame failed: \(avErrorString(ret))")
        }

        if let vctx = videoCodecCtx { avcodec_flush_buffers(vctx) }
        if let actx = audioCodecCtx { avcodec_flush_buffers(actx) }
    }

    func close() {
        if let f = frame { av_frame_free(&self.frame) }
        if let p = packet { av_packet_free(&self.packet) }
        if let s = swsCtx { sws_freeContext(s); swsCtx = nil }
        if videoCodecCtx != nil { avcodec_free_context(&videoCodecCtx) }
        if audioCodecCtx != nil { avcodec_free_context(&audioCodecCtx) }
        if formatCtx != nil { avformat_close_input(&formatCtx) }
        isOpen = false
    }

    deinit {
        close()
    }

    // MARK: - Private

    private static let avTimeBase: Int64 = 1_000_000
    private let averrorEOF: Int32 = {
        // AVERROR_EOF = FFERRTAG('E','O','F',' ') which is a negative tag
        let e = Int32(bitPattern: UInt32(Character("E").asciiValue!) |
                                  (UInt32(Character("O").asciiValue!) << 8) |
                                  (UInt32(Character("F").asciiValue!) << 16) |
                                  (UInt32(Character(" ").asciiValue!) << 24))
        return -e
    }()

    private func openDecoder(streamIndex: Int32, codecCtx: inout UnsafeMutablePointer<AVCodecContext>?) throws {
        guard let ctx = formatCtx else { throw FormatBridgeError.decodeFailed("Not open") }
        let stream = ctx.pointee.streams[Int(streamIndex)]!
        let codecpar = stream.pointee.codecpar!

        guard let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            let name = avcodec_get_name(codecpar.pointee.codec_id)
            throw FormatBridgeError.decoderNotFound(codec: String(cString: name!))
        }

        codecCtx = avcodec_alloc_context3(decoder)
        guard let cctx = codecCtx else {
            throw FormatBridgeError.decodeFailed("avcodec_alloc_context3 failed")
        }

        var ret = avcodec_parameters_to_context(cctx, codecpar)
        guard ret >= 0 else {
            throw FormatBridgeError.decodeFailed("avcodec_parameters_to_context failed: \(avErrorString(ret))")
        }

        ret = avcodec_open2(cctx, decoder, nil)
        guard ret >= 0 else {
            throw FormatBridgeError.decodeFailed("avcodec_open2 failed: \(avErrorString(ret))")
        }
    }

    private func decodeVideoPacket(
        _ pkt: UnsafeMutablePointer<AVPacket>,
        frame: UnsafeMutablePointer<AVFrame>
    ) throws -> DecodedVideoFrame? {
        guard let cctx = videoCodecCtx else { return nil }

        var ret = avcodec_send_packet(cctx, pkt)
        if ret == negEAGAIN { return nil }
        guard ret >= 0 else { return nil }

        ret = avcodec_receive_frame(cctx, frame)
        if ret == negEAGAIN || ret == averrorEOF { return nil }
        guard ret >= 0 else { return nil }
        defer { av_frame_unref(frame) }

        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)

        let pixelBuffer = try convertToPixelBuffer(frame: frame, width: width, height: height, srcFmt: srcFmt)

        let pts = frame.pointee.best_effort_timestamp
        let presentationTime = TimestampMapper.cmTime(
            fromPTS: pts, timebaseNum: videoTBNum, timebaseDen: videoTBDen
        )

        let dur = frame.pointee.duration
        let duration: CMTime
        if dur > 0 {
            duration = TimestampMapper.duration(
                fromPacketDuration: dur, timebaseNum: videoTBNum, timebaseDen: videoTBDen
            )
        } else {
            // Estimate from frame rate
            let stream = formatCtx!.pointee.streams[Int(videoStreamIndex)]!
            let fr = stream.pointee.avg_frame_rate
            if fr.num > 0 && fr.den > 0 {
                duration = CMTimeMake(value: Int64(fr.den), timescale: fr.num)
            } else {
                duration = CMTimeMake(value: 1, timescale: 24) // fallback
            }
        }

        return DecodedVideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            duration: duration
        )
    }

    private func decodeAudioPacket(
        _ pkt: UnsafeMutablePointer<AVPacket>,
        frame: UnsafeMutablePointer<AVFrame>
    ) throws -> DecodedAudioBuffer? {
        guard let cctx = audioCodecCtx else { return nil }

        var ret = avcodec_send_packet(cctx, pkt)
        if ret == negEAGAIN {
            // Internal buffer full — caller should drain frames first, then retry
            return nil
        }
        guard ret >= 0 else {
            // Skip bad packets instead of failing the whole decode
            return nil
        }

        ret = avcodec_receive_frame(cctx, frame)
        if ret == negEAGAIN || ret == averrorEOF { return nil }
        guard ret >= 0 else {
            return nil // Skip decode errors on individual frames
        }
        defer { av_frame_unref(frame) }

        let pts = frame.pointee.best_effort_timestamp
        let presentationTime = TimestampMapper.cmTime(
            fromPTS: pts, timebaseNum: audioTBNum, timebaseDen: audioTBDen
        )

        let sampleBuffer = try createAudioSampleBuffer(from: frame, pts: presentationTime)

        return DecodedAudioBuffer(
            sampleBuffer: sampleBuffer,
            presentationTime: presentationTime
        )
    }

    // MARK: - Pixel Buffer Conversion

    private func convertToPixelBuffer(
        frame: UnsafeMutablePointer<AVFrame>,
        width: Int, height: Int,
        srcFmt: AVPixelFormat
    ) throws -> CVPixelBuffer {
        let dstFmt = AV_PIX_FMT_NV12

        // Create or reconfigure sws context
        swsCtx = sws_getCachedContext(
            swsCtx,
            Int32(width), Int32(height), srcFmt,
            Int32(width), Int32(height), dstFmt,
            SWS_BILINEAR, nil, nil, nil
        )
        guard swsCtx != nil else {
            throw FormatBridgeError.decodeFailed("sws_getCachedContext failed")
        }

        // Pin swscale's colourspace so the YUV→NV12 repack doesn't apply its
        // DEFAULT (= ITU-601, SWS_CS_DEFAULT) matrix to an UNTAGGED source — that
        // bakes a 601-vs-709 colour drift into the decode, and thus into the
        // VideoToolbox encode (which tags output 709): on untagged HD signage the
        // measured VMAF collapsed (sevilla 82.9 vs 95) and the shipped colours
        // drifted (#61). Use the source's tagged matrix, else the standard
        // heuristic (BT.709 for HD ≥720, BT.601 for SD). src == dst colourspace +
        // matched range → a clean repack, no conversion.
        let useBT709: Bool
        switch frame.pointee.colorspace {
        case AVCOL_SPC_BT709: useBT709 = true
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M, AVCOL_SPC_SMPTE240M: useBT709 = false
        default: useBT709 = height >= 720
        }
        if let coeffs = sws_getCoefficients(useBT709 ? SWS_CS_ITU709 : SWS_CS_ITU601) {
            let srcRange: Int32 = (frame.pointee.color_range == AVCOL_RANGE_JPEG) ? 1 : 0
            _ = sws_setColorspaceDetails(swsCtx, coeffs, srcRange, coeffs, 0, 0, 1 << 16, 1 << 16)
        }

        let pixelBuffer = try pixelBufferConverter.createPixelBuffer(
            width: width, height: height,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        // Tag the decoded buffer's colour so VideoToolbox encode + any YUV→RGB use
        // the same matrix the repack above assumed (consistent end-to-end, #61).
        let matrix = useBT709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        let primaries = useBT709 ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        // NV12 has two planes: Y and UV
        let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
        let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
        let yStride = Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
        let uvStride = Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))

        var dstData: [UnsafeMutablePointer<UInt8>?] = [
            yPlane.assumingMemoryBound(to: UInt8.self),
            uvPlane.assumingMemoryBound(to: UInt8.self),
            nil, nil
        ]
        var dstLinesize: [Int32] = [yStride, uvStride, 0, 0]

        let d = frame.pointee.data
        var srcData: [UnsafePointer<UInt8>?] = [
            UnsafePointer(d.0), UnsafePointer(d.1), UnsafePointer(d.2), UnsafePointer(d.3)
        ]
        let ls = frame.pointee.linesize
        var srcLinesize: [Int32] = [ls.0, ls.1, ls.2, ls.3]

        sws_scale(swsCtx, &srcData, &srcLinesize, 0, Int32(height), &dstData, &dstLinesize)

        return pixelBuffer
    }

    // MARK: - Audio Sample Buffer

    private func createAudioSampleBuffer(from frame: UnsafeMutablePointer<AVFrame>, pts: CMTime) throws -> CMSampleBuffer {
        let channels = Int(frame.pointee.ch_layout.nb_channels)
        let sampleRate = Float64(frame.pointee.sample_rate)
        let numSamples = Int(frame.pointee.nb_samples)

        // Create AudioStreamBasicDescription for float32 interleaved PCM
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let desc = formatDesc else {
            throw FormatBridgeError.decodeFailed("CMAudioFormatDescriptionCreate failed: \(status)")
        }

        // Convert FFmpeg audio to interleaved float32
        let dataSize = numSamples * channels * 4
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: numSamples * channels)
        defer { buffer.deallocate() }

        let srcFmt = AVSampleFormat(rawValue: frame.pointee.format)
        if srcFmt == AV_SAMPLE_FMT_FLTP {
            // Planar float — interleave
            let ad = frame.pointee.data
            let chPtrs: [UnsafeMutablePointer<UInt8>?] = [ad.0, ad.1, ad.2, ad.3, ad.4, ad.5, ad.6, ad.7]
            for ch in 0..<channels {
                guard ch < chPtrs.count, let rawPtr = chPtrs[ch] else { continue }
                let src = UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Float.self)
                for s in 0..<numSamples {
                    buffer[s * channels + ch] = src[s]
                }
            }
        } else {
            // Best effort: copy raw bytes
            if let srcPtr = frame.pointee.data.0 {
                memcpy(buffer, srcPtr, min(dataSize, Int(frame.pointee.linesize.0)))
            }
        }

        // Create CMBlockBuffer
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let block = blockBuffer else {
            throw FormatBridgeError.decodeFailed("CMBlockBufferCreate failed: \(status)")
        }

        status = CMBlockBufferReplaceDataBytes(
            with: buffer, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize
        )
        guard status == noErr else {
            throw FormatBridgeError.decodeFailed("CMBlockBufferReplaceDataBytes failed: \(status)")
        }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: block,
            formatDescription: desc,
            sampleCount: numSamples,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else {
            throw FormatBridgeError.decodeFailed("CMAudioSampleBufferCreate failed: \(status)")
        }

        return sb
    }

    private let negEAGAIN: Int32 = -11 // EAGAIN on macOS
}
