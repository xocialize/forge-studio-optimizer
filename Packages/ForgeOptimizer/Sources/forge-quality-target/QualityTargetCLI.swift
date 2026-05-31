//
// QualityTargetCLI.swift
// forge-quality-target
//
// Runs the native Step-1 VMAF-targeted encode (ADR-0013/0014) on a real clip,
// end to end:
//
//   decode (FormatBridge) → VMAF-targeted constant-quality search
//   (VideoToolboxQualityTargetEncoder + FFmpegVMAFScorer) → final HEVC encode
//
// and reports the chosen quality, the achieved VMAF, and the bitrate savings vs
// the source at that guaranteed quality. This is the keystone the #54 gate
// builds on (run it across the high-bitrate corpus subset, compare to a flat
// floor-guaranteeing baseline).
//
// Memory note: the search re-encodes the sampled frames once per probe, so we
// decode a bounded SAMPLE (first --max-frames frames, default 120). NV12 frames
// are fed straight to VideoToolbox (its native format) — no BGRA roundtrip — so
// a 1080p sample is ~3 MB/frame.
//

import CoreMedia
import CoreVideo
import Foundation
import FormatBridge
import ForgeOptimizer

@main
struct QualityTargetCLI {

    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("forge-quality-target: error: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Options

    struct Options {
        var input: URL
        var targetVMAF: Double = 95
        var codec: OutputVideoCodec = .hevc
        var maxFrames: Int = 120
        var maxProbes: Int = 8
        var slack: Double = 0.5
        var keepOutput: URL?
        // Restore mode (degraded "bad file" input, no pristine reference):
        // decode → NAFNet restore → re-encode at a fixed quality.
        var restore: Bool = false
        var fixedQuality: Float = 0.6
    }

    enum CLIError: Error, CustomStringConvertible {
        case usage(String), noVideoStream, decodeEmpty, ffmpeg(String)
        var description: String {
            switch self {
            case .usage(let s): return "\(s)\n\n\(usageText)"
            case .noVideoStream: return "input has no video stream"
            case .decodeEmpty: return "decoded zero frames"
            case .ffmpeg(let s): return "ffmpeg: \(s)"
            }
        }
    }

    static let usageText = """
    usage: forge-quality-target --input <clip> [options]
      --input,  -i  <path>   source clip (required)
      --target, -t  <vmaf>   target VMAF floor (default 95)
      --codec       hevc|h264 (default hevc)
      --max-frames  <n>      sample frame cap (default 120)
      --max-probes  <n>      sample-encode probe cap (default 8)
      --slack       <pts>    accept VMAF >= target - slack (default 0.5)
      --out         <path>   also keep the final targeted encode here

    restore mode (degraded "bad file" input, no pristine reference):
      --restore              decode → NAFNet restore → re-encode (needs --out)
      --quality     <0..1>   fixed encode quality for restore (default 0.6)
    """

    static func parse() throws -> Options {
        var input: URL?
        var o = Options(input: URL(fileURLWithPath: "/dev/null"))
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--input", "-i": input = it.next().map { URL(fileURLWithPath: $0) }
            case "--target", "-t": if let v = it.next().flatMap(Double.init) { o.targetVMAF = v }
            case "--codec": o.codec = (it.next() == "h264") ? .h264 : .hevc
            case "--max-frames": if let v = it.next().flatMap(Int.init) { o.maxFrames = v }
            case "--max-probes": if let v = it.next().flatMap(Int.init) { o.maxProbes = v }
            case "--slack": if let v = it.next().flatMap(Double.init) { o.slack = v }
            case "--out": o.keepOutput = it.next().map { URL(fileURLWithPath: $0) }
            case "--restore": o.restore = true
            case "--quality": if let v = it.next().flatMap(Float.init) { o.fixedQuality = v }
            case "--help", "-h": print(usageText); exit(0)
            default: throw CLIError.usage("unknown argument: \(a)")
            }
        }
        guard let input else { throw CLIError.usage("missing --input") }
        o.input = input
        return o
    }

    // MARK: - Run

    static func run() async throws {
        let o = try parse()
        if o.restore { try await runRestore(o); return }
        let ffmpeg = FFmpegVMAFScorer.resolveFFmpeg()

        // 1. Probe the source.
        let info = try await FormatBridgeFactory.makeProbe().probe(url: o.input)
        guard let vs = info.videoStreams.first else { throw CLIError.noVideoStream }
        let fps = vs.frameRate > 0 ? vs.frameRate : 30.0

        log("source   : \(o.input.lastPathComponent)  \(vs.width)x\(vs.height) "
            + "@ \(fmt(fps)) fps  \(vs.codec)  "
            + (vs.bitrate.map { "\(fmt(Double($0) / 1e6)) Mbps" } ?? "bitrate ?"))
        log("target   : VMAF ≥ \(fmt(o.targetVMAF)) (slack \(fmt(o.slack)))  codec \(o.codec)")

        // 2. Decode a bounded NV12 sample (deep-copied — decoder pools recycle).
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: o.input)
        var frames: [CVPixelBuffer] = []
        frames.reserveCapacity(o.maxFrames)
        while frames.count < o.maxFrames, let f = try await decoder.decodeNextVideoFrame() {
            frames.append(copy(f.pixelBuffer))
        }
        decoder.close()
        guard !frames.isEmpty else { throw CLIError.decodeEmpty }
        let sampleSeconds = Double(frames.count) / fps
        log("sample   : \(frames.count) frames (\(fmt(sampleSeconds)) s)")

        // 3. Lossless ffv1 reference built from the SAME decoded frames we feed
        //    the encoder — so VMAF measures pure encode loss, with no cross-
        //    pipeline frame-order or colour-range mismatch (an ffmpeg re-decode
        //    of the source as reference scored a bogus ~76 even at max quality).
        let w = CVPixelBufferGetWidth(frames[0])
        let h = CVPixelBufferGetHeight(frames[0])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fqt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reference = tmp.appendingPathComponent("ref.mkv")
        try buildReference(frames: frames, width: w, height: h, fps: fps,
                           to: reference, ffmpeg: ffmpeg)

        // 4. VMAF-targeted encode.
        let scorer = FFmpegVMAFScorer(ffmpegPath: ffmpeg)
        let search = QualityTargetSearch(targetScore: o.targetVMAF, slack: o.slack,
                                         maxProbes: o.maxProbes)
        let encoder = FormatBridgeFactory.makeQualityTargetEncoder(scorer: scorer, search: search)
        let settings = VideoEncoderSettings(codec: o.codec, resolution: .original,
                                            frameRate: .target(fps))
        let output = o.keepOutput ?? tmp.appendingPathComponent("targeted.mp4")
        log("searching: sample-encode binary search over the quality knob …")

        let clock = Date()
        let result = try await encoder.encode(frames: frames, reference: reference,
                                              output: output, settings: settings)
        let elapsed = Date().timeIntervalSince(clock)

        // 5. Report.
        let outBytes = fileSize(output)
        let targetedBitrate = Double(outBytes) * 8.0 / max(sampleSeconds, 1e-6) // bits/s
        log("")
        log("── result ─────────────────────────────────────────────")
        log("chosen quality : \(fmt(Double(result.quality), 3))   "
            + "(\(result.metTarget ? "met target" : "TARGET UNREACHABLE — ceiling"))")
        log("achieved VMAF  : \(fmt(result.achievedScore))   over \(result.probeCount) probes, \(fmt(elapsed)) s")
        log("targeted size  : \(fmt(Double(outBytes) / 1e6)) MB  →  \(fmt(targetedBitrate / 1e6)) Mbps")
        if let src = vs.bitrate, src > 0 {
            let savings = (1.0 - targetedBitrate / Double(src)) * 100.0
            log("source bitrate : \(fmt(Double(src) / 1e6)) Mbps")
            log(String(format: "SAVINGS vs src : %.1f%% smaller at a guaranteed VMAF ≥ %@",
                       savings, fmt(o.targetVMAF)))
        }
        if let keep = o.keepOutput { log("kept output    : \(keep.path)") }
    }

    // MARK: - Restore mode

    /// Degraded "bad file" path: decode → NAFNet restore → re-encode at a fixed
    /// quality. No pristine reference exists (the degraded file IS the input),
    /// so there's no VMAF-vs-source here — the comparison is restoration /
    /// perceptual (visual A/B on matched frames, NR-IQA, size). Streams one
    /// frame at a time to keep 4K memory bounded.
    static func runRestore(_ o: Options) async throws {
        guard let out = o.keepOutput else { throw CLIError.usage("--restore requires --out") }
        let info = try await FormatBridgeFactory.makeProbe().probe(url: o.input)
        guard let vs = info.videoStreams.first else { throw CLIError.noVideoStream }
        let fps = vs.frameRate > 0 ? vs.frameRate : 30.0
        log("source : \(o.input.lastPathComponent)  \(vs.width)x\(vs.height) @ \(fmt(fps)) fps  "
            + (vs.bitrate.map { "\(fmt(Double($0) / 1e6)) Mbps" } ?? "bitrate ?"))
        log("restore: NAFNet → VideoToolbox \(o.codec) @ quality \(fmt(Double(o.fixedQuality), 2)), "
            + "up to \(o.maxFrames) frames")

        let nafnet = try NAFNetProcessor()
        let encoder = FormatBridgeFactory.makeQualityEncoder()
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: o.input)

        let timescale: Int32 = 600
        let frameDur = CMTime(value: Int64(Double(timescale) / fps), timescale: timescale)
        var i = 0
        var configured = false
        let clock = Date()
        while i < o.maxFrames, let f = try await decoder.decodeNextVideoFrame() {
            let restored = nafnet.process(f.pixelBuffer)
            if !configured {
                let w = CVPixelBufferGetWidth(restored), h = CVPixelBufferGetHeight(restored)
                let settings = VideoEncoderSettings(codec: o.codec,
                                                    resolution: .custom(width: w, height: h),
                                                    frameRate: .target(fps),
                                                    constantQuality: o.fixedQuality)
                try encoder.configure(output: out, videoSettings: settings, audioSettings: nil)
                configured = true
            }
            try encoder.appendVideoFrame(restored,
                                         at: CMTimeMultiply(frameDur, multiplier: Int32(i)),
                                         duration: frameDur)
            i += 1
            if i % 20 == 0 { log("  …restored \(i) frames") }
        }
        decoder.close()
        guard configured else { throw CLIError.decodeEmpty }
        try await encoder.finish()

        let dt = Date().timeIntervalSince(clock)
        let outBytes = fileSize(out)
        let secs = Double(i) / fps
        log("")
        log("── restored ───────────────────────────────────────────")
        log("frames : \(i) in \(fmt(dt)) s  (\(fmt(Double(i) / max(dt, 1e-6))) fps)")
        log("output : \(fmt(Double(outBytes) / 1e6)) MB  →  \(fmt(Double(outBytes) * 8 / max(secs, 1e-6) / 1e6)) Mbps")
        log("kept   : \(out.path)")
    }

    // MARK: - ffmpeg reference

    /// Lossless ffv1 reference piped from the in-memory NV12 sample frames, so
    /// the reference and the distorted encode share identical source pixels.
    static func buildReference(frames: [CVPixelBuffer], width w: Int, height h: Int,
                               fps: Double, to out: URL, ffmpeg: String) throws {
        guard CVPixelBufferGetPixelFormatType(frames[0]) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || CVPixelBufferGetPixelFormatType(frames[0]) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            throw CLIError.ffmpeg("expected NV12 frames for the reference, got "
                + "\(CVPixelBufferGetPixelFormatType(frames[0]))")
        }
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "rawvideo", "-pixel_format", "nv12",
                       "-video_size", "\(w)x\(h)",
                       "-framerate", String(format: "%.6f", fps),
                       "-i", "pipe:0", "-an",
                       "-c:v", "ffv1", out.path]
        let inPipe = Pipe(), err = Pipe()
        p.standardInput = inPipe
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let fh = inPipe.fileHandleForWriting
        for frame in frames { fh.write(repackNV12(frame, w, h)) }
        try? fh.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            let log = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CLIError.ffmpeg("reference build failed: \(log.suffix(400))")
        }
    }

    /// Tightly repack an NV12 CVPixelBuffer (Y plane then interleaved CbCr) into
    /// `pipe:0` rawvideo bytes, stripping any per-plane row padding.
    static func repackNV12(_ pb: CVPixelBuffer, _ w: Int, _ h: Int) -> Data {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var out = Data(capacity: w * h + w * (h / 2))
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let base = y.assumingMemoryBound(to: UInt8.self)
            for row in 0 ..< h { out.append(base + row * bpr, count: w) }
        }
        if let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let base = c.assumingMemoryBound(to: UInt8.self)
            for row in 0 ..< (h / 2) { out.append(base + row * bpr, count: w) }
        }
        return out
    }

    // MARK: - Helpers

    /// Deep-copy a CVPixelBuffer (planar-aware) so sampled frames survive the
    /// decoder's buffer-pool recycling.
    static func copy(_ src: CVPixelBuffer) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let fmt = CVPixelBufferGetPixelFormatType(src)
        var dst: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &dst)
        let d = dst!
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(d, [])
        defer {
            CVPixelBufferUnlockBaseAddress(d, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        if CVPixelBufferIsPlanar(src) {
            for plane in 0 ..< CVPixelBufferGetPlaneCount(src) {
                guard let sBase = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                      let dBase = CVPixelBufferGetBaseAddressOfPlane(d, plane) else { continue }
                let sBpr = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
                let dBpr = CVPixelBufferGetBytesPerRowOfPlane(d, plane)
                let ph = CVPixelBufferGetHeightOfPlane(src, plane)
                let n = min(sBpr, dBpr)
                for y in 0 ..< ph { memcpy(dBase + y * dBpr, sBase + y * sBpr, n) }
            }
        } else if let sBase = CVPixelBufferGetBaseAddress(src),
                  let dBase = CVPixelBufferGetBaseAddress(d) {
            let sBpr = CVPixelBufferGetBytesPerRow(src), dBpr = CVPixelBufferGetBytesPerRow(d)
            let n = min(sBpr, dBpr)
            for y in 0 ..< h { memcpy(dBase + y * dBpr, sBase + y * sBpr, n) }
        }
        return d
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    }

    static func fmt(_ v: Double, _ places: Int = 2) -> String {
        String(format: "%.\(places)f", v)
    }

    static func log(_ s: String) { print(s) }
}
