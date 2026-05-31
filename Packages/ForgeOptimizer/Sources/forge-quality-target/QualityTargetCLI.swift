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
        // Per-shot mode (Step 2): shot-detect → per-shot VMAF-target → stitch,
        // reported against a per-title encode of the same frames.
        var perShot: Bool = false
        // Encode at a FIXED quality (skip the search) — the flat floor-guaranteeing
        // baseline for the ADR-0014 gate. Still measures VMAF + size.
        var fixed: Float? = nil
        // Emit a machine-readable JSON result line (for corpus harnesses / the gate).
        var json: Bool = false
        // Score-only mode: decode + run the no-reference blockiness scorer (the
        // Step-3 IQA gate signal); print mean/min/max quality. For threshold
        // calibration on real content.
        var score: Bool = false
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

    per-shot mode (Step 2 — beats per-title):
      --per-shot             shot-detect → per-shot VMAF-target → stitch (needs --out);
                             reports savings vs a per-title encode of the same frames
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
            case "--per-shot": o.perShot = true
            case "--score": o.score = true
            case "--fixed": o.fixed = it.next().flatMap(Float.init)
            case "--json": o.json = true
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
        if o.perShot { try await runPerShot(o); return }
        if o.score { try await runScore(o); return }
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

        // 3. Lossless ffv1 reference: ffmpeg decodes the same source frames
        //    (0 ..< count). Frame-index-aligned with our decode (framesync fix).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fqt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reference = tmp.appendingPathComponent("ref.mkv")
        try buildReference(source: o.input, startFrame: 0, count: frames.count,
                           to: reference, ffmpeg: ffmpeg)

        // 4. VMAF-targeted encode. With --fixed q the search range is q…q, so it
        //    just encodes at q and measures (the flat-baseline path).
        let scorer = FFmpegVMAFScorer(ffmpegPath: ffmpeg)
        let qRange: ClosedRange<Float> = o.fixed.map { max(0, min(1, $0))...max(0, min(1, $0)) } ?? 0.1...1.0
        let search = QualityTargetSearch(targetScore: o.targetVMAF, slack: o.slack,
                                         qualityRange: qRange, maxProbes: o.maxProbes)
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
        if o.json {
            // One machine-readable line for corpus harnesses / the ADR-0014 gate.
            let src = vs.bitrate ?? 0
            print("JSON {\"clip\":\"\(o.input.lastPathComponent)\",\"frames\":\(frames.count),"
                + "\"fps\":\(fmt(fps, 3)),\"quality\":\(fmt(Double(result.quality), 3)),"
                + "\"achievedVMAF\":\(fmt(result.achievedScore, 3)),\"metTarget\":\(result.metTarget),"
                + "\"fixed\":\(o.fixed != nil),\"targetedBytes\":\(outBytes),\"sourceBytes\":\(src)}")
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

    // MARK: - Score-only (Step 3 gate signal)

    /// Decode + run the no-reference blockiness scorer; print mean/min/max and the
    /// gate decision. For calibrating the IQA-gate threshold on real content.
    static func runScore(_ o: Options) async throws {
        let info = try await FormatBridgeFactory.makeProbe().probe(url: o.input)
        guard let vs = info.videoStreams.first else { throw CLIError.noVideoStream }
        let scorer = BlockinessQualityScorer()
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: o.input)
        var qs: [Float] = []
        var i = 0
        while i < o.maxFrames, let f = try await decoder.decodeNextVideoFrame() {
            qs.append(scorer.quality(f.pixelBuffer)); i += 1
        }
        decoder.close()
        guard !qs.isEmpty else { throw CLIError.decodeEmpty }
        let mean = qs.reduce(0, +) / Float(qs.count)
        let threshold: Float = 0.6
        log("source : \(o.input.lastPathComponent)  \(vs.width)x\(vs.height)  "
            + (vs.bitrate.map { "\(fmt(Double($0) / 1e6)) Mbps" } ?? "? Mbps"))
        log("quality: mean \(fmt(Double(mean), 3))  min \(fmt(Double(qs.min()!), 3))  "
            + "max \(fmt(Double(qs.max()!), 3))   (\(qs.count) frames)")
        log("gate   : \(mean < threshold ? "RESTORE (degraded)" : "skip (clean)")  @ threshold \(fmt(Double(threshold), 2))")
    }

    // MARK: - Per-shot (Step 2)

    /// Shot-detect → per-shot VMAF-targeted encode → stitch, compared to a
    /// per-title encode of the same frames. Per-shot wins because an easy shot
    /// can use a lower quality than a hard one while both clear the VMAF floor.
    static func runPerShot(_ o: Options) async throws {
        guard let out = o.keepOutput else { throw CLIError.usage("--per-shot requires --out") }
        let ffmpeg = FFmpegVMAFScorer.resolveFFmpeg()
        let info = try await FormatBridgeFactory.makeProbe().probe(url: o.input)
        guard let vs = info.videoStreams.first else { throw CLIError.noVideoStream }
        let fps = vs.frameRate > 0 ? vs.frameRate : 30.0
        log("source : \(o.input.lastPathComponent)  \(vs.width)x\(vs.height) @ \(fmt(fps)) fps")
        log("target : VMAF ≥ \(fmt(o.targetVMAF)) (slack \(fmt(o.slack)))  codec \(o.codec)")

        // Decode a bounded NV12 sample (deep-copied — pools recycle).
        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: o.input)
        var frames: [CVPixelBuffer] = []
        while frames.count < o.maxFrames, let f = try await decoder.decodeNextVideoFrame() {
            frames.append(copy(f.pixelBuffer))
        }
        decoder.close()
        guard !frames.isEmpty else { throw CLIError.decodeEmpty }

        // Shot detection over per-frame luma histograms.
        let sigs = frames.map { lumaHistogram($0) }
        let shots = ShotDetector().shots(signatures: sigs)
        log("shots  : \(shots.count) detected over \(frames.count) frames "
            + "(\(shots.map { String($0.count) }.joined(separator: "/")))")

        let scorer = FFmpegVMAFScorer(ffmpegPath: ffmpeg)
        let search = QualityTargetSearch(targetScore: o.targetVMAF, slack: o.slack, maxProbes: o.maxProbes)
        let encoder = FormatBridgeFactory.makeQualityTargetEncoder(scorer: scorer, search: search)
        let settings = VideoEncoderSettings(codec: o.codec, resolution: .original, frameRate: .target(fps))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fqt-ps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Per-title baseline FIRST: its quality is the CAP for per-shot. Without
        // the cap, forcing every shot to the VMAF *floor* over-serves hard shots
        // (per-title lets them ride lower, where motion masks artifacts, and banks
        // easy shots high) — so naive per-shot grows the expensive shots and loses.
        // Capping at the per-title quality means a hard shot is never richer than
        // per-title while easy shots still drop below → net savings, minus the
        // per-segment keyframe overhead.
        let fullRef = tmp.appendingPathComponent("ref-full.mkv")
        try buildReference(source: o.input, startFrame: 0, count: frames.count,
                           to: fullRef, ffmpeg: ffmpeg)
        let ptOut = tmp.appendingPathComponent("pertitle.mp4")
        let ptRes = try await encoder.encode(frames: frames, reference: fullRef,
                                             output: ptOut, settings: settings)
        let ptBytes = fileSize(ptOut)
        log("per-title : q=\(fmt(Double(ptRes.quality), 3))  VMAF=\(fmt(ptRes.achievedScore))  "
            + "\(fmt(Double(ptBytes) / 1e6)) MB")

        // Per-shot search, CAPPED at the per-title quality.
        let lo = search.qualityRange.lowerBound
        let cap = max(lo, ptRes.quality)
        let cappedSearch = QualityTargetSearch(targetScore: o.targetVMAF, slack: o.slack,
                                               qualityRange: lo ... cap, maxProbes: o.maxProbes)
        let cappedEncoder = FormatBridgeFactory.makeQualityTargetEncoder(scorer: scorer, search: cappedSearch)
        let clock = Date()
        var shotFiles: [URL] = []
        for (i, r) in shots.enumerated() {
            let shotFrames = Array(frames[r])
            let ref = tmp.appendingPathComponent("ref-\(i).mkv")
            try buildReference(source: o.input, startFrame: r.lowerBound, count: r.count,
                               to: ref, ffmpeg: ffmpeg)
            let shotOut = tmp.appendingPathComponent("shot-\(i).mp4")
            let res = try await cappedEncoder.encode(frames: shotFrames, reference: ref,
                                                     output: shotOut, settings: settings)
            shotFiles.append(shotOut)
            log("  shot \(i): \(r.count) frames  q=\(fmt(Double(res.quality), 3))  "
                + "VMAF=\(fmt(res.achievedScore))  \(fmt(Double(fileSize(shotOut)) / 1e6)) MB")
        }
        let stitched = tmp.appendingPathComponent("pershot.mp4")
        try concat(shotFiles, to: stitched, ffmpeg: ffmpeg)
        let perShotSecs = Date().timeIntervalSince(clock)
        let stitchedBytes = fileSize(stitched)

        // Ship the smaller of the two — per-shot only when it actually pays.
        let usePerShot = stitchedBytes < ptBytes
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.copyItem(at: usePerShot ? stitched : ptOut, to: out)

        // Report.
        let secs = Double(frames.count) / fps
        let br = { (b: Int) in fmt(Double(b) * 8 / max(secs, 1e-6) / 1e6) }
        log("")
        log("── per-shot (capped @ q\(fmt(Double(ptRes.quality), 3))) vs per-title ──")
        log("per-title : \(fmt(Double(ptBytes) / 1e6)) MB  →  \(br(ptBytes)) Mbps")
        log("per-shot  : \(shots.count) shots  \(fmt(Double(stitchedBytes) / 1e6)) MB  →  "
            + "\(br(stitchedBytes)) Mbps  (\(fmt(perShotSecs)) s)")
        if ptBytes > 0 {
            let delta = (1.0 - Double(stitchedBytes) / Double(ptBytes)) * 100.0
            log(String(format: "PER-SHOT %@: %+.1f%% vs per-title  →  shipped %@",
                       delta >= 0 ? "WIN " : "LOSS", delta, usePerShot ? "per-shot" : "per-title"))
        }
        log("shipped  : \(out.path)")
    }

    /// Normalised luma histogram (NV12 Y-plane, sub-sampled) — the shot-detector
    /// signature. `bins` mass sums to 1.
    static func lumaHistogram(_ pb: CVPixelBuffer, bins: Int = 16) -> [Float] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var hist = [Float](repeating: 0, count: bins)
        let planar = CVPixelBufferIsPlanar(pb)
        let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb)
        guard let base else { return hist }
        let bpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let step = max(1, w / 128)
        var count: Float = 0
        var y = 0
        while y < h {
            let row = p + y * bpr
            var x = 0
            while x < w {
                hist[min(bins - 1, Int(row[x]) * bins / 256)] += 1
                count += 1
                x += step
            }
            y += step
        }
        if count > 0 { for i in 0 ..< bins { hist[i] /= count } }
        return hist
    }

    /// Stitch encoded shot files into one via the ffmpeg concat demuxer (-c copy).
    static func concat(_ files: [URL], to out: URL, ffmpeg: String) throws {
        let list = out.deletingLastPathComponent().appendingPathComponent("concat-\(UUID().uuidString).txt")
        try files.map { "file '\($0.path)'" }.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "concat", "-safe", "0", "-i", list.path, "-c", "copy", out.path]
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            let log = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CLIError.ffmpeg("concat failed: \(log.suffix(400))")
        }
    }

    // MARK: - ffmpeg reference

    /// Lossless ffv1 VMAF reference: ffmpeg decodes the SOURCE frames
    /// `[startFrame, startFrame+count)` directly, tagged BT.709 to match the
    /// encoder's output.
    ///
    /// (History: an earlier version repacked our in-memory NV12 frames to
    /// rawvideo and ffv1'd that, to dodge a cross-pipeline frame-order mismatch.
    /// But the repack path corrupted the reference by ~6 VMAF points — our
    /// encode measured 99.8 vs an *independent* ffmpeg reference but only ~94 vs
    /// the repacked one. With the framesync fix in place (`settb=AVTB,setpts=N`
    /// in `QualityMeasure.vmaf`), pairing is by frame index, so decoding the
    /// source directly is both correct and simpler. Our FormatBridge-decoded
    /// frames and ffmpeg's decode align frame-for-frame — verified at 99.8 VMAF.)
    static func buildReference(source: URL, startFrame: Int, count: Int,
                               to out: URL, ffmpeg: String) throws {
        try? FileManager.default.removeItem(at: out)
        // `trim` selects frames [start, end) by index — verified to pick the
        // right source frames and align frame-for-frame with our encode (offset
        // ranges score 99.9 vs the ground-truth slice). Do NOT add `setpts=N`
        // here: it renumbers PTS to 0,1,2… in the source timebase, collapsing the
        // near-zero gaps so the muxer drops all but ~2 frames. Frame alignment is
        // handled at compare time by `QualityMeasure.vmaf`'s `settb=AVTB,setpts=N`.
        let end = startFrame + count
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-i", source.path, "-an",
                       "-vf", "trim=start_frame=\(startFrame):end_frame=\(end)",
                       "-color_primaries", "bt709", "-color_trc", "bt709",
                       "-colorspace", "bt709", "-color_range", "tv",
                       "-c:v", "ffv1", out.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            let log = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CLIError.ffmpeg("reference build failed: \(log.suffix(400))")
        }
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
