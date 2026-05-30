import FFmpegXC
import Foundation

/// Extracts subtitle streams from containers and writes them as sidecar files.
/// Supports SRT, ASS/SSA text-based subtitle formats. PGS/VobSub (bitmap) are skipped.
struct SubtitleExtractor {

    /// Extract all text-based subtitle streams from a media file.
    /// - Parameters:
    ///   - inputURL: Source media file
    ///   - outputDir: Directory for sidecar subtitle files
    ///   - baseName: Base filename (without extension) for output files
    ///   - subtitleStreams: Subtitle stream info from FormatProbe
    /// - Returns: Array of paths to extracted subtitle files
    static func extract(
        from inputURL: URL,
        to outputDir: URL,
        baseName: String,
        subtitleStreams: [SubtitleStreamInfo]
    ) throws -> [URL] {
        let textCodecs = Set(["subrip", "srt", "ass", "ssa", "webvtt", "mov_text"])

        let extractable = subtitleStreams.filter { textCodecs.contains($0.codec) }
        guard !extractable.isEmpty else { return [] }

        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        var ret = avformat_open_input(&fmtCtx, inputURL.path, nil, nil)
        guard ret == 0, let ctx = fmtCtx else {
            throw FormatBridgeError.probeFailed("Cannot open \(inputURL.lastPathComponent) for subtitle extraction")
        }
        defer { avformat_close_input(&fmtCtx) }

        ret = avformat_find_stream_info(ctx, nil)
        guard ret >= 0 else { return [] }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var extractedPaths: [URL] = []
        var pktPtr: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        guard let pkt = pktPtr else { return [] }
        defer { av_packet_free(&pktPtr) }

        for subInfo in extractable {
            let streamIdx = Int32(subInfo.index)
            let lang = subInfo.language ?? "und"
            let ext = (subInfo.codec == "ass" || subInfo.codec == "ssa") ? "ass" : "srt"
            let outputURL = outputDir.appendingPathComponent("\(baseName).\(lang).\(ext)")

            // Collect all packets for this subtitle stream
            var packets: [(pts: Int64, data: Data)] = []

            // Reset to beginning for each stream
            av_seek_frame(ctx, -1, 0, AVSEEK_FLAG_BACKWARD)

            while av_read_frame(ctx, pkt) >= 0 {
                defer { av_packet_unref(pkt) }

                if pkt.pointee.stream_index == streamIdx {
                    if let data = pkt.pointee.data {
                        let size = Int(pkt.pointee.size)
                        let packetData = Data(bytes: data, count: size)
                        packets.append((pts: pkt.pointee.pts, data: packetData))
                    }
                }
            }

            guard !packets.isEmpty else { continue }

            // Get stream timebase for PTS conversion
            let stream = ctx.pointee.streams[Int(streamIdx)]!
            let tb = stream.pointee.time_base

            if ext == "srt" {
                let srtContent = convertToSRT(packets: packets, timebaseNum: tb.num, timebaseDen: tb.den)
                try srtContent.write(to: outputURL, atomically: true, encoding: .utf8)
            } else {
                // ASS/SSA: extract the codec extradata (header) + events
                let header: String
                if let codecpar = stream.pointee.codecpar,
                   codecpar.pointee.extradata != nil,
                   codecpar.pointee.extradata_size > 0 {
                    header = String(
                        bytes: Data(bytes: codecpar.pointee.extradata,
                                    count: Int(codecpar.pointee.extradata_size)),
                        encoding: .utf8
                    ) ?? ""
                } else {
                    header = ""
                }

                let assContent = convertToASS(header: header, packets: packets,
                                               timebaseNum: tb.num, timebaseDen: tb.den)
                try assContent.write(to: outputURL, atomically: true, encoding: .utf8)
            }

            extractedPaths.append(outputURL)
        }

        return extractedPaths
    }

    // MARK: - SRT Conversion

    private static func convertToSRT(
        packets: [(pts: Int64, data: Data)],
        timebaseNum: Int32,
        timebaseDen: Int32
    ) -> String {
        var lines: [String] = []

        for (index, packet) in packets.enumerated() {
            guard let text = String(data: packet.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }

            let startSeconds = Double(packet.pts) * Double(timebaseNum) / Double(timebaseDen)
            // Estimate duration: use 3 seconds default if unknown
            let endSeconds = startSeconds + 3.0

            lines.append("\(index + 1)")
            lines.append("\(formatSRTTime(startSeconds)) --> \(formatSRTTime(endSeconds))")
            lines.append(text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func formatSRTTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - ASS Conversion

    private static func convertToASS(
        header: String,
        packets: [(pts: Int64, data: Data)],
        timebaseNum: Int32,
        timebaseDen: Int32
    ) -> String {
        var content = header
        if !content.hasSuffix("\n") { content += "\n" }

        // ASS packets contain the dialogue line after the ReadOrder,Layer,... prefix
        for packet in packets {
            guard let text = String(data: packet.data, encoding: .utf8) else { continue }
            let startSeconds = Double(packet.pts) * Double(timebaseNum) / Double(timebaseDen)
            let endSeconds = startSeconds + 3.0

            let start = formatASSTime(startSeconds)
            let end = formatASSTime(endSeconds)

            // MKV ASS packets are: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            // We prepend "Dialogue: " and the timing
            content += "Dialogue: 0,\(start),\(end),\(text)\n"
        }

        return content
    }

    private static func formatASSTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let cs = Int((seconds - Double(Int(seconds))) * 100)
        return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
    }
}
