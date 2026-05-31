//
// BenchmarkRunner.swift
// ForgeOptimizer / Benchmark
//
// Real (non-stubbed) runtime path that drives one clip through
// FFmpegDecoder → PreprocessorFactory chain → NativeEncoder, captures
// per-frame timing + peak memory, and produces a populated
// `OptimizerRun` record.
//
// Lives in a separate file from `BenchmarkSuite` because the suite is
// an actor and this runner does CPU-bound work outside actor isolation
// (decode loops, AVAssetWriter, ContinuousClock measurements). Keeping
// the runner non-isolated keeps the cost-of-isolation off the hot path
// and lets the suite remain a simple accumulator.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import AVFoundation
import CoreMedia
import CoreVideo
import FormatBridge
import ForgeUpscaler
import Foundation
import VideoToolbox

#if canImport(Darwin)
import Darwin
import Darwin.Mach
#endif

enum BenchmarkRunnerError: Error, CustomStringConvertible {
    case encoderConfigure(String)

    var description: String {
        switch self {
        case .encoderConfigure(let detail):
            return "encoder configuration failed: \(detail)"
        }
    }
}

/// Synthesizes one `OptimizerRun` from the v0.3 legacy chain.
///
/// Pure value type. Each call to `runOptimizerPass` does a fresh
/// decode → preprocess → encode cycle and records timing/memory/quality.
/// No state is retained between runs.
public struct BenchmarkRunner: Sendable {

    /// Directory containing the clip files (`<clipID>.mp4`). Defaults
    /// to `Forge/Tests/Corpus/clips` relative to the corpus manifest;
    /// callers may override for tests.
    public let clipsDirectory: URL

    /// Path to ffmpeg-full (used by the VMAF subprocess in
    /// `QualityMeasure`). Defaults to the ADR-0002 location.
    public let ffmpegFullPath: String

    /// Whether to attempt a VMAF measurement per clip. Defaults to true;
    /// the CI runner toggles this off when ffmpeg-full isn't available.
    public let computeVMAF: Bool

    public init(
        clipsDirectory: URL,
        ffmpegFullPath: String = QualityMeasure.defaultFFmpegPath,
        computeVMAF: Bool = true
    ) {
        self.clipsDirectory = clipsDirectory
        self.ffmpegFullPath = ffmpegFullPath
        self.computeVMAF = computeVMAF
    }

    // MARK: - SR low-resolution input (proper full-reference SR benchmark)

    /// Produce a clean bicubic-downscaled (÷`factor`) copy of `source` to
    /// serve as the SR model's low-resolution input.
    ///
    /// This implements the standard full-reference super-resolution
    /// benchmark: the corpus clip is the high-resolution GROUND TRUTH, we
    /// downscale it to make the LR input, the model upscales that back
    /// toward the original, and quality is measured (VMAF) against the
    /// original. The earlier path fed the full-res clip straight in and
    /// "measured" the N× output against the same-res source — no ground
    /// truth, so VMAF was meaningless and, at mismatched dimensions, errored
    /// outright. (Degradation-aware LR — compression artefacts on top of the
    /// downscale — is the separate option in ADR-0006; this is the clean
    /// DIV2K-bicubic variant.)
    ///
    /// Near-lossless h264 (CRF 12) so the LR carries no meaningful codec
    /// degradation: the bicubic downscale is the only intended information
    /// loss. Cached per (clip, factor) under a stable temp dir so the four
    /// backends in a C.4 A/B reuse a single downscale instead of redoing it
    /// 4×. `-nostdin` for the same loop-safety reason as the corpus scripts.
    ///
    /// Returns the LR file URL plus its exact dimensions (`srcW/srcH`
    /// integer-divided by `factor`).
    func makeDownscaledClip(
        source: URL,
        clipID: String,
        factor: Int,
        srcW: Int,
        srcH: Int
    ) throws -> (url: URL, lrW: Int, lrH: Int) {
        let lrW = max(2, (srcW / factor) / 2 * 2)   // keep even for yuv420p
        let lrH = max(2, (srcH / factor) / 2 * 2)
        let fm = FileManager.default
        let cacheDir = fm.temporaryDirectory.appendingPathComponent("forge-bench-lr-cache")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let lrURL = cacheDir.appendingPathComponent("\(clipID)-lr-x\(factor).mp4")

        if fm.fileExists(atPath: lrURL.path) {
            return (lrURL, lrW, lrH)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegFullPath)
        process.arguments = [
            "-nostdin", "-y", "-loglevel", "error",
            "-i", source.path,
            "-vf", "scale=\(lrW):\(lrH):flags=bicubic",
            "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", "-an",
            lrURL.path,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, fm.fileExists(atPath: lrURL.path) else {
            let log = String(data: errData, encoding: .utf8) ?? ""
            throw BenchmarkRunnerError.encoderConfigure(
                "LR downscale failed (exit \(process.terminationStatus)): \(log.suffix(400))"
            )
        }
        return (lrURL, lrW, lrH)
    }

    /// Probe a video's pixel dimensions via ffprobe (sibling of ffmpegFullPath).
    /// Used by the external-LR upscaler mode to size a real HD source whose
    /// dimensions aren't HR/scale.
    func probeVideoDimensions(_ url: URL) -> (w: Int, h: Int)? {
        let ffprobe = URL(fileURLWithPath: ffmpegFullPath)
            .deletingLastPathComponent().appendingPathComponent("ffprobe").path
        guard FileManager.default.fileExists(atPath: ffprobe) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height",
            "-of", "csv=p=0:s=x", url.path,
        ]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = s.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }

    /// Re-encode `src` scaled to `toW`×`toH` (bicubic, crf 12, video-only) at
    /// `dst`. Used to bring the external-LR SR output back to master resolution
    /// before VMAF.
    func scaleVideo(_ src: URL, toW: Int, toH: Int, dst: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegFullPath)
        p.arguments = [
            "-nostdin", "-y", "-loglevel", "error",
            "-i", src.path,
            "-vf", "scale=\(toW):\(toH):flags=bicubic",
            "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", "-an",
            dst.path,
        ]
        let errPipe = Pipe(); p.standardError = errPipe
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: dst.path) else {
            let log = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BenchmarkRunnerError.encoderConfigure(
                "scaleVideo failed (exit \(p.terminationStatus)): \(log.suffix(300))")
        }
    }

    // MARK: - Optimizer pass

    /// Drive one clip × one level through the legacy chain and synthesize
    /// an `OptimizerRun`. Never throws — every failure mode collapses
    /// into a `.failed` (or `.partial`) record with a `failureReason`.
    public func runOptimizerPass(
        level: OptimizerRun.OptimizationLevel,
        clip: CorpusClip
    ) async -> OptimizerRun {
        let clipURL = clipsDirectory.appendingPathComponent("\(clip.id).mp4")
        let fm = FileManager.default

        // Materialization gate — schema-stable failure with a clear
        // reason so the runner can fan out across the manifest even
        // before fetch_corpus.sh has populated every clip.
        guard fm.fileExists(atPath: clipURL.path) else {
            return OptimizerRun(
                clipID: clip.id,
                optimizationLevel: level,
                resolution: clip.resolution,
                status: .failed,
                failureReason: "clip not materialized; run fetch_corpus.sh --id \(clip.id)"
            )
        }

        // Build the FrameProcessor chain. The factory uses the legacy
        // sync inits which pull bundled .mlpackage files via
        // CoreMLProcessor — the same code path the Forge app uses
        // today. PreprocessorFactory consumes FormatBridge's
        // OptimizationLevel; map from the report's enum.
        let chainLevel = Self.mapToFormatBridgeLevel(level)
        let chain: (any FrameProcessor)?
        do {
            chain = try PreprocessorFactory.makeChain(for: chainLevel)
        } catch {
            return OptimizerRun(
                clipID: clip.id,
                optimizationLevel: level,
                resolution: clip.resolution,
                status: .failed,
                failureReason: "PreprocessorFactory.makeChain failed: \(error)"
            )
        }

        // Temp output URL inside a per-run dir so concurrent runs don't
        // collide. The runner cleans up after itself.
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("forge-benchmark-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("\(clip.id)-\(level.rawValue).mp4")

        // Pull dimensions from manifest (preferred) or default. The
        // encoder also accepts `.original` but we want a deterministic
        // size in the report.
        let (width, height) = Self.parseResolution(clip.resolution)
        guard width > 0, height > 0 else {
            return OptimizerRun(
                clipID: clip.id,
                optimizationLevel: level,
                resolution: clip.resolution,
                status: .failed,
                failureReason: "Invalid resolution string '\(clip.resolution)'"
            )
        }
        let frameRate = clip.frameRate ?? 30.0

        let decoder = FormatBridgeFactory.makeDecoder()
        // For the benchmark we use a direct AVAssetWriter (video-only)
        // rather than FormatBridge's NativeEncoder. NativeEncoder
        // always configures an audio input alongside the video input;
        // when we never push audio (we don't — the benchmark measures
        // the optimizer chain, not audio passthrough) the writer
        // stalls after ~40 frames waiting for interleaving data. The
        // direct encoder skips the audio input entirely so the writer
        // drains video continuously.
        let qualityValue: Double = {
            switch Self.qualityPreset(for: level) {
            case .low: return 0.25
            case .medium: return 0.5
            case .high: return 0.75
            case .maximum: return 1.0
            }
        }()

        // Outcome accumulators — populated as the pipeline progresses.
        var perFrameMs: [Double] = []
        var firstFrameMs: Double = 0.0
        var frameCount: Int = 0
        var peakResidentBytes: UInt64 = currentResidentBytes()
        var stagePartial: String? = nil
        var psnrSum: Double = 0.0
        var ssimSum: Double = 0.0
        var psnrCount: Int = 0
        var ssimCount: Int = 0
        var drainAbortReason: String? = nil

        do {
            try await decoder.open(url: clipURL)

            // Direct AVAssetWriter (video-only) — see note above.
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            // H.264 (avc1) does NOT accept AVVideoQualityKey — that's a
            // ProRes property. Use an explicit average bitrate derived
            // from pixel-rate × ~0.1 bits/px instead (sensible default
            // for benchmark reproducibility; SR quality is measured in
            // the pixel domain via PSNR/SSIM/VMAF, not the encoded file).
            let pixelsPerFrame = Double(width * height)
            let avgBitrate = Int(pixelsPerFrame * frameRate * 0.1)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: avgBitrate,
                    AVVideoAllowFrameReorderingKey: true,
                    AVVideoExpectedSourceFrameRateKey: frameRate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ] as [String: Any],
            ]
            _ = qualityValue  // optimizer-level quality target preserved
                              // for documentation; no longer fed into
                              // the encoder settings dictionary.
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            let adaptorAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: adaptorAttrs
            )
            guard writer.canAdd(videoInput) else {
                throw BenchmarkRunnerError.encoderConfigure("AVAssetWriter rejected video input")
            }
            writer.add(videoInput)
            guard writer.startWriting() else {
                throw BenchmarkRunnerError.encoderConfigure(
                    "AVAssetWriter.startWriting failed: \(writer.error?.localizedDescription ?? "unknown")"
                )
            }
            writer.startSession(atSourceTime: .zero)

            drainAbortReason = await drainDecoder(
                decoder: decoder,
                adaptor: adaptor,
                input: videoInput,
                chain: chain,
                frameRate: frameRate,
                perFrameMs: &perFrameMs,
                firstFrameMs: &firstFrameMs,
                frameCount: &frameCount,
                peakResidentBytes: &peakResidentBytes,
                psnrSum: &psnrSum,
                ssimSum: &ssimSum,
                psnrCount: &psnrCount,
                ssimCount: &ssimCount,
                clip: clip
            )

            videoInput.markAsFinished()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer.finishWriting { cont.resume() }
            }
            decoder.close()
            if writer.status != .completed {
                if drainAbortReason == nil {
                    drainAbortReason = "AVAssetWriter status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "unknown")"
                }
            }
            if let reason = drainAbortReason {
                stagePartial = reason
            }
        } catch {
            // Pipeline aborted mid-stream. Decide partial vs failed
            // based on whether we produced any timed frames.
            decoder.close()
            if frameCount > 0 {
                stagePartial = "encode/decode aborted after \(frameCount) frames: \(error)"
            } else {
                return OptimizerRun(
                    clipID: clip.id,
                    optimizationLevel: level,
                    resolution: clip.resolution,
                    status: .failed,
                    failureReason: "decode/encode failed: \(error)"
                )
            }
        }

        // Speed metrics — exclude the first frame from mean/median/p95/
        // p99/stddev per schema §1. fps is derived from mean.
        let tail = perFrameMs.dropFirst()
        let sorted = tail.sorted()
        let mean = sorted.isEmpty ? 0.0 : sorted.reduce(0, +) / Double(sorted.count)
        let median = sorted.isEmpty ? 0.0 : Self.percentile(sorted, 0.5)
        let p95 = Self.percentile(sorted, 0.95)
        let p99 = Self.percentile(sorted, 0.99)
        let stddev = Self.stddev(values: sorted, mean: mean)
        let fpsMean = mean > 0 ? 1000.0 / mean : 0.0
        let realtime = frameRate > 0 ? fpsMean / frameRate : 0.0

        let speed = SpeedMetrics(
            msPerFrameMean: mean,
            msPerFrameMedian: median,
            msPerFrameP95: p95,
            msPerFrameP99: p99,
            msPerFrameStddev: stddev,
            msFirstFrame: firstFrameMs > 0 ? firstFrameMs : nil,
            realtimeFactor: realtime,
            fpsMean: fpsMean
        )

        // Quality — PSNR/SSIM aggregated across sampled frames during
        // the loop. VMAF runs as a one-shot ffmpeg subprocess over the
        // input + output files. LPIPS stays nil (see scope).
        let psnrAvg = psnrCount > 0 ? psnrSum / Double(psnrCount) : nil
        let ssimAvg = ssimCount > 0 ? ssimSum / Double(ssimCount) : nil
        var vmafScore: Double? = nil
        if computeVMAF, FileManager.default.fileExists(atPath: outputURL.path) {
            let qm = QualityMeasure()
            do {
                vmafScore = try await qm.vmaf(
                    referenceURL: clipURL,
                    testURL: outputURL,
                    ffmpegPath: ffmpegFullPath
                )
            } catch {
                // VMAF failure isn't fatal — leave nil and downgrade to
                // partial if everything else succeeded.
                if stagePartial == nil {
                    stagePartial = "VMAF subprocess failed: \(error)"
                }
            }
        }
        let quality = QualityMetrics(
            vmaf: vmafScore,
            psnrDB: psnrAvg,
            ssim: ssimAvg,
            lpips: nil  // stub per scope
        )

        // Memory — peak resident bytes captured during the decode loop.
        let memory = MemoryMetrics(
            peakBytes: Int(peakResidentBytes),
            steadyStateBytes: nil,
            modelResidentBytes: nil
        )

        // Compression — input file size vs output file size. Ratio
        // computed by the caller / harness driver when an `.off` run is
        // available (we don't have visibility into other levels here).
        let inputBytes = (try? fm.attributesOfItem(atPath: clipURL.path)[.size] as? Int) ?? 0
        let outputBytes = (try? fm.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        let compression = CompressionMetrics(
            inputBytes: inputBytes,
            outputBytes: outputBytes,
            ratioVsBaseline: nil,
            savingsVsBaseline: nil,
            encoder: "h264_videotoolbox",
            encoderSettings: [
                "codec": AnyCodable("h264"),
                "quality": AnyCodable(Self.qualityPresetName(for: level)),
                "hardware_acceleration": AnyCodable(true),
            ]
        )

        let status: RunStatus = stagePartial == nil ? .success : .partial
        return OptimizerRun(
            clipID: clip.id,
            optimizationLevel: level,
            resolution: "\(width)x\(height)",
            frameCount: frameCount,
            speed: speed,
            quality: quality,
            memory: memory,
            compression: compression,
            status: status,
            failureReason: stagePartial
        )
    }

    // MARK: - Compression pass (CRF vs source, #40)

    /// Optimize one clip at one level and encode it at a constant-quality CRF
    /// target via ffmpeg (libx264), then report **savings vs the source file**
    /// — the real product metric (Forge re-encodes the master smaller while
    /// holding quality; NAFNet restoration lets the encoder go harder). This is
    /// the §4 compression-gate path. Additive: the AVAssetWriter optimizer pass
    /// (fixed bitrate, used by C.4/B.5) is untouched.
    ///
    /// `savingsVsBaseline` here is savings-vs-source (1 − out/source); the gate
    /// reads that field. VMAF is the optimized output vs the source.
    public func runCompressionCRFPass(
        level: OptimizerRun.OptimizationLevel,
        clip: CorpusClip,
        crf: Int
    ) async -> OptimizerRun {
        let clipURL = clipsDirectory.appendingPathComponent("\(clip.id).mp4")
        let fm = FileManager.default
        let (width, height) = Self.parseResolution(clip.resolution)
        guard fm.fileExists(atPath: clipURL.path), width > 0, height > 0 else {
            return OptimizerRun(
                clipID: clip.id, optimizationLevel: level, resolution: clip.resolution,
                status: .failed,
                failureReason: "clip not materialized or bad resolution '\(clip.resolution)'")
        }

        let chain: (any FrameProcessor)?
        do {
            chain = try PreprocessorFactory.makeChain(for: Self.mapToFormatBridgeLevel(level))
        } catch {
            return OptimizerRun(
                clipID: clip.id, optimizationLevel: level, resolution: clip.resolution,
                status: .failed, failureReason: "makeChain failed: \(error)")
        }

        let frameRate = clip.frameRate ?? 30.0
        let tempDir = fm.temporaryDirectory.appendingPathComponent("forge-crf-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        let outURL = tempDir.appendingPathComponent("\(clip.id)-\(level.rawValue)-crf\(crf).mp4")

        // ffmpeg reading raw BGRA from stdin → libx264 CRF.
        let ff = Process()
        ff.executableURL = URL(fileURLWithPath: ffmpegFullPath)
        ff.arguments = [
            "-f", "rawvideo", "-pixel_format", "bgra",
            "-video_size", "\(width)x\(height)", "-framerate", "\(frameRate)",
            "-i", "pipe:0", "-an",
            "-c:v", "libx264", "-preset", "medium", "-crf", "\(crf)", "-pix_fmt", "yuv420p",
            "-y", outURL.path,
        ]
        let stdinPipe = Pipe(); ff.standardInput = stdinPipe
        let errPipe = Pipe(); ff.standardError = errPipe
        let fh = stdinPipe.fileHandleForWriting

        let decoder = FormatBridgeFactory.makeDecoder()
        var frameCount = 0
        var perFrameMs: [Double] = []
        var firstFrameMs = 0.0
        var abortReason: String? = nil
        let rowBytes = width * 4

        do {
            try await decoder.open(url: clipURL)
            try ff.run()
            let clock = ContinuousClock()
            while true {
                let frame = try await decoder.decodeNextVideoFrame()
                guard let video = frame else { break }
                let start = clock.now
                let processed = chain?.process(video.pixelBuffer) ?? video.pixelBuffer
                let el = clock.now - start
                let ms = Double(el.components.seconds) * 1000.0 + Double(el.components.attoseconds) / 1e15
                perFrameMs.append(ms)
                if frameCount == 0 { firstFrameMs = ms }
                frameCount += 1

                // Pack to tight BGRA (strip row padding) and write one frame.
                let bgra = ensureBGRA(processed)
                CVPixelBufferLockBaseAddress(bgra, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(bgra) {
                    let bpr = CVPixelBufferGetBytesPerRow(bgra)
                    let src = base.assumingMemoryBound(to: UInt8.self)
                    var packed = [UInt8](repeating: 0, count: rowBytes * height)
                    packed.withUnsafeMutableBufferPointer { dst in
                        for y in 0 ..< height {
                            memcpy(dst.baseAddress! + y * rowBytes, src + y * bpr, rowBytes)
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
                    do { try fh.write(contentsOf: Data(packed)) }
                    catch { abortReason = "ffmpeg pipe write failed at frame \(frameCount): \(error)"; break }
                } else {
                    CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
                }
            }
        } catch {
            abortReason = "decode/encode aborted at frame \(frameCount): \(error)"
        }
        decoder.close()
        try? fh.close()
        ff.waitUntilExit()

        guard frameCount > 0, ff.terminationStatus == 0, fm.fileExists(atPath: outURL.path) else {
            let log = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return OptimizerRun(
                clipID: clip.id, optimizationLevel: level, resolution: "\(width)x\(height)",
                frameCount: frameCount, status: .failed,
                failureReason: "CRF encode failed (exit \(ff.terminationStatus), frames \(frameCount)): "
                    + (abortReason ?? "") + " " + String(log.suffix(300)))
        }

        let outBytes = ((try? fm.attributesOfItem(atPath: outURL.path)[.size]) as? Int) ?? 0
        let srcBytes = ((try? fm.attributesOfItem(atPath: clipURL.path)[.size]) as? Int) ?? 0
        let ratio = srcBytes > 0 ? Double(outBytes) / Double(srcBytes) : nil
        let savings = ratio.map { 1.0 - $0 }

        var vmaf: Double? = nil
        let qm = QualityMeasure()
        vmaf = try? await qm.vmaf(referenceURL: clipURL, testURL: outURL, ffmpegPath: ffmpegFullPath)

        let tail = perFrameMs.dropFirst().sorted()
        let mean = tail.isEmpty ? 0.0 : tail.reduce(0, +) / Double(tail.count)
        let speed = SpeedMetrics(
            msPerFrameMean: mean,
            msPerFrameMedian: Self.percentile(tail, 0.5),
            msPerFrameP95: Self.percentile(tail, 0.95),
            msPerFrameP99: Self.percentile(tail, 0.99),
            msPerFrameStddev: Self.stddev(values: tail, mean: mean),
            msFirstFrame: firstFrameMs > 0 ? firstFrameMs : nil,
            realtimeFactor: frameRate > 0 && mean > 0 ? (1000.0 / mean) / frameRate : 0.0,
            fpsMean: mean > 0 ? 1000.0 / mean : 0.0
        )
        let compression = CompressionMetrics(
            inputBytes: srcBytes,
            outputBytes: outBytes,
            ratioVsBaseline: ratio,
            savingsVsBaseline: savings,
            encoder: "libx264",
            encoderSettings: [
                "codec": AnyCodable("h264"),
                "crf": AnyCodable(crf),
                "baseline": AnyCodable("source"),
            ]
        )
        return OptimizerRun(
            clipID: clip.id, optimizationLevel: level, resolution: "\(width)x\(height)",
            frameCount: frameCount, speed: speed,
            quality: QualityMetrics(vmaf: vmaf, psnrDB: nil, ssim: nil, lpips: nil),
            memory: nil, compression: compression,
            status: abortReason == nil ? .success : .partial, failureReason: abortReason)
    }

    // MARK: - Upscaler pass

    /// Drive one clip × one playback backend through the real upscaler
    /// runtime and synthesize a populated `UpscalerRun`.
    ///
    /// Replaces the Phase A.2 stub that returned `.failed` with
    /// `"ForgeUpscaler weights not yet vendored (SRVGGNet/RRDBNet); Phase C/D scope"`.
    /// Both EfRLFN and SRVGGNetCompact ship as MLX-Swift modules with
    /// vendored safetensors (Phases C.3 + C.5a / Task #28) so the load
    /// path now succeeds at runtime.
    ///
    /// Like `runOptimizerPass`, this method never throws — every failure
    /// collapses into a `.failed` (or `.partial`) record with a
    /// `failureReason`. The `backend` field on the returned
    /// `UpscalerRun` carries the tier identifier (`tier.name`) so the
    /// C.4 A/B JSON can attribute each row to the backend that produced
    /// it.
    /// - Parameter externalLR: when set, the SR input is this file (e.g. a real
    ///   Vimeo HD encode) instead of a clean ÷scale downscale of the clip. The
    ///   clip is then treated purely as the HR reference: the SR output
    ///   (lr×scale) is downscaled to the clip's master resolution and VMAF'd
    ///   against the clip. This is the controlled HD→master product test
    ///   ("does Forge SR of a real HD source beat bicubic on the 4K wall?").
    public func runUpscalerPass(
        backend: PlaybackBackendID,
        scale: Int = 4,
        clip: CorpusClip,
        externalLR: URL? = nil
    ) async -> UpscalerRun {
        let inputRes = clip.resolution
        let outputRes = Self.scaleResolution(inputRes, factor: scale)
        let tierName = "\(backend.rawValue)-x\(scale)"

        // Scale × backend gate — surface a clean reason before we ever
        // touch the file system.
        guard backend.supportsScale(scale) else {
            return UpscalerRun(
                clipID: clip.id,
                inputResolution: inputRes,
                outputResolution: outputRes,
                scaleFactor: scale,
                status: .failed,
                failureReason: "only scale=4 supported for srvggnet-* (no x2 weights vendored)",
                backend: tierName
            )
        }

        let clipURL = clipsDirectory.appendingPathComponent("\(clip.id).mp4")
        let fm = FileManager.default
        guard fm.fileExists(atPath: clipURL.path) else {
            return UpscalerRun(
                clipID: clip.id,
                inputResolution: inputRes,
                outputResolution: outputRes,
                scaleFactor: scale,
                status: .failed,
                failureReason: "clip not materialized; run fetch_corpus.sh --id \(clip.id)",
                backend: tierName
            )
        }

        // Build the playback tier via `PlaybackUpscaler(backend:)` — this
        // is the additive Phase C.5a entry point. Using the preset shim
        // would route through C.5a defaults and mask the A/B.
        let playback: PlaybackUpscaler
        do {
            playback = try PlaybackUpscaler(backend: backend.toPlaybackBackend(scale: scale))
        } catch {
            return UpscalerRun(
                clipID: clip.id,
                inputResolution: inputRes,
                outputResolution: outputRes,
                scaleFactor: scale,
                status: .failed,
                failureReason: "PlaybackUpscaler init failed: \(error)",
                backend: tierName
            )
        }
        let tier = playback.tier
        // Prefer the tier's own `name` (authoritative) for the JSON
        // attribution; fall back to our synthesised `<backend>-x<scale>`
        // if a future tier reports something else.
        let backendLabel = tier.name

        let (width, height) = Self.parseResolution(inputRes)
        guard width > 0, height > 0 else {
            return UpscalerRun(
                clipID: clip.id,
                inputResolution: inputRes,
                outputResolution: outputRes,
                scaleFactor: scale,
                status: .failed,
                failureReason: "Invalid resolution string '\(inputRes)'",
                backend: backendLabel
            )
        }
        // LR input. Default (full-reference SR benchmark): downscale the clip
        // ÷scale; the model upscales THAT back toward the original (VMAF ground
        // truth). External-LR mode: use the provided real HD encode directly
        // (its native dims, NOT clip/scale) — the clip stays the HR reference.
        let lrInfo: (url: URL, lrW: Int, lrH: Int)
        let externalLRMode = externalLR != nil
        if let externalLR {
            guard fm.fileExists(atPath: externalLR.path) else {
                return UpscalerRun(
                    clipID: clip.id, inputResolution: inputRes,
                    outputResolution: outputRes, scaleFactor: scale,
                    status: .failed,
                    failureReason: "external LR not found: \(externalLR.path)",
                    backend: backendLabel
                )
            }
            guard let dims = probeVideoDimensions(externalLR) else {
                return UpscalerRun(
                    clipID: clip.id, inputResolution: inputRes,
                    outputResolution: outputRes, scaleFactor: scale,
                    status: .failed,
                    failureReason: "could not probe external LR dimensions: \(externalLR.lastPathComponent)",
                    backend: backendLabel
                )
            }
            // Keep even for the encoder; the model takes the frames as decoded.
            lrInfo = (externalLR, dims.w / 2 * 2, dims.h / 2 * 2)
        } else {
            do {
                lrInfo = try makeDownscaledClip(
                    source: clipURL, clipID: clip.id, factor: scale,
                    srcW: width, srcH: height
                )
            } catch {
                return UpscalerRun(
                    clipID: clip.id,
                    inputResolution: inputRes,
                    outputResolution: outputRes,
                    scaleFactor: scale,
                    status: .failed,
                    failureReason: "LR downscale failed: \(error)",
                    backend: backendLabel
                )
            }
        }
        let srInputURL = lrInfo.url
        let lrResolution = "\(lrInfo.lrW)x\(lrInfo.lrH)"
        // SR output ≈ HR ground truth (LR×scale). NOT width×scale (that was
        // the broken N×-the-source path that produced 8K outputs vs an HR
        // reference of a different size).
        let outW = lrInfo.lrW * scale
        let outH = lrInfo.lrH * scale
        let outputResolution = "\(outW)x\(outH)"
        let frameRate = clip.frameRate ?? 30.0

        // Per-run temp dir for the upscaled output mp4.
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("forge-benchmark-up-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // DIAGNOSTIC: FORGE_KEEP_TEMP=<dir> copies the SR output mp4 there
        // instead of letting it vanish with the per-run temp dir.
        let keepDir = ProcessInfo.processInfo.environment["FORGE_KEEP_TEMP"]
        defer {
            if let keepDir {
                let dst = URL(fileURLWithPath: keepDir)
                    .appendingPathComponent("\(clip.id)-\(backendLabel).mp4")
                try? fm.createDirectory(at: URL(fileURLWithPath: keepDir), withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: tempDir.appendingPathComponent("\(clip.id)-\(backendLabel).mp4"), to: dst)
            }
            try? fm.removeItem(at: tempDir)
        }
        let outputURL = tempDir.appendingPathComponent("\(clip.id)-\(backendLabel).mp4")

        let decoder = FormatBridgeFactory.makeDecoder()

        // Accumulators.
        var perFrameMs: [Double] = []
        var firstFrameMs: Double = 0.0
        var frameCount: Int = 0
        var peakResidentBytes: UInt64 = currentResidentBytes()
        var stagePartial: String? = nil
        var psnrSum: Double = 0.0
        var ssimSum: Double = 0.0
        var psnrCount: Int = 0
        var ssimCount: Int = 0
        var drainAbortReason: String? = nil

        do {
            // Decode the LR input (the SR model upscales this); the original
            // clipURL stays the VMAF reference / ground truth.
            try await decoder.open(url: srInputURL)

            // Direct AVAssetWriter at the OUTPUT (upscaled) resolution.
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            // Same H.264 / AVVideoQualityKey issue as runOptimizerPass — use
            // an explicit average bitrate derived from the OUTPUT pixel rate
            // (post-upscale). 0.1 bits/px × pixels × fps is a sensible
            // benchmark default; the SR quality measurement is in the pixel
            // domain via PSNR/SSIM/VMAF, not the encoded mp4.
            let outPixelsPerFrame = Double(outW * outH)
            let avgBitrate = Int(outPixelsPerFrame * frameRate * 0.1)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outW,
                AVVideoHeightKey: outH,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: avgBitrate,
                    AVVideoAllowFrameReorderingKey: true,
                    AVVideoExpectedSourceFrameRateKey: frameRate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ] as [String: Any],
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            let adaptorAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: adaptorAttrs
            )
            guard writer.canAdd(videoInput) else {
                throw BenchmarkRunnerError.encoderConfigure("AVAssetWriter rejected video input")
            }
            writer.add(videoInput)
            guard writer.startWriting() else {
                throw BenchmarkRunnerError.encoderConfigure(
                    "AVAssetWriter.startWriting failed: \(writer.error?.localizedDescription ?? "unknown")"
                )
            }
            writer.startSession(atSourceTime: .zero)

            drainAbortReason = await drainUpscaler(
                decoder: decoder,
                adaptor: adaptor,
                input: videoInput,
                tier: tier,
                frameRate: frameRate,
                perFrameMs: &perFrameMs,
                firstFrameMs: &firstFrameMs,
                frameCount: &frameCount,
                peakResidentBytes: &peakResidentBytes,
                psnrSum: &psnrSum,
                ssimSum: &ssimSum,
                psnrCount: &psnrCount,
                ssimCount: &ssimCount
            )

            videoInput.markAsFinished()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer.finishWriting { cont.resume() }
            }
            decoder.close()
            if writer.status != .completed {
                if drainAbortReason == nil {
                    drainAbortReason = "AVAssetWriter status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "unknown")"
                }
            }
            if let reason = drainAbortReason {
                stagePartial = reason
            }
        } catch {
            decoder.close()
            if frameCount > 0 {
                stagePartial = "encode/decode aborted after \(frameCount) frames: \(error)"
            } else {
                return UpscalerRun(
                    clipID: clip.id,
                    inputResolution: inputRes,
                    outputResolution: outputResolution,
                    scaleFactor: scale,
                    frameCount: 0,
                    status: .failed,
                    failureReason: "decode/upscale failed: \(error)",
                    backend: backendLabel
                )
            }
        }

        // Speed metrics — same shape as the optimizer pass. First frame
        // excluded from mean/median/p95/p99/stddev per schema §1.
        let tail = perFrameMs.dropFirst()
        let sorted = tail.sorted()
        let mean = sorted.isEmpty ? 0.0 : sorted.reduce(0, +) / Double(sorted.count)
        let median = sorted.isEmpty ? 0.0 : Self.percentile(sorted, 0.5)
        let p95 = Self.percentile(sorted, 0.95)
        let p99 = Self.percentile(sorted, 0.99)
        let stddev = Self.stddev(values: sorted, mean: mean)
        let fpsMean = mean > 0 ? 1000.0 / mean : 0.0
        let realtime = frameRate > 0 ? fpsMean / frameRate : 0.0

        let speed = SpeedMetrics(
            msPerFrameMean: mean,
            msPerFrameMedian: median,
            msPerFrameP95: p95,
            msPerFrameP99: p99,
            msPerFrameStddev: stddev,
            msFirstFrame: firstFrameMs > 0 ? firstFrameMs : nil,
            realtimeFactor: realtime,
            fpsMean: fpsMean
        )

        // Quality — VMAF (the ADR-0006 ship-criterion metric) as a one-shot
        // ffmpeg subprocess comparing the SR output (test) against the
        // ORIGINAL HR clip (reference / ground truth). Valid because the SR
        // output ≈ HR resolution (we upscaled the ÷scale LR back up), so
        // VMAF measures reconstruction quality, not similarity-to-bicubic.
        // PSNR/SSIM are left nil here — the in-loop accumulators can't see
        // the HR frame (the loop decodes LR), and full-reference PSNR/SSIM
        // would need a second decode of the original; VMAF is the gate metric
        // and a richer one-shot PSNR/SSIM pass is a possible follow-up.
        // LPIPS stub per scope.
        let psnrAvg = psnrCount > 0 ? psnrSum / Double(psnrCount) : nil
        let ssimAvg = ssimCount > 0 ? ssimSum / Double(ssimCount) : nil
        var vmafScore: Double? = nil
        if computeVMAF, FileManager.default.fileExists(atPath: outputURL.path) {
            let qm = QualityMeasure()
            // External-LR mode: the SR output is (real-HD × scale), larger than
            // the master. Downscale it to the master resolution so VMAF is a
            // clean same-res compare against the HR reference (the wall res),
            // not a scale2ref'd compare at the oversized SR resolution.
            var testURL = outputURL
            if externalLRMode {
                let atMaster = tempDir.appendingPathComponent("\(clip.id)-atmaster.mp4")
                do {
                    try scaleVideo(outputURL, toW: width, toH: height, dst: atMaster)
                    testURL = atMaster
                } catch {
                    if stagePartial == nil {
                        stagePartial = "downscale-to-master failed: \(error)"
                    }
                }
            }
            do {
                vmafScore = try await qm.vmaf(
                    referenceURL: clipURL,    // master HR = ground truth
                    testURL: testURL,         // SR output (at master res in external mode)
                    ffmpegPath: ffmpegFullPath
                )
            } catch {
                if stagePartial == nil {
                    stagePartial = "VMAF subprocess failed: \(error)"
                }
            }
        }
        let quality = QualityMetrics(
            vmaf: vmafScore,
            psnrDB: psnrAvg,
            ssim: ssimAvg,
            lpips: nil
        )

        let memory = MemoryMetrics(
            peakBytes: Int(peakResidentBytes),
            steadyStateBytes: nil,
            modelResidentBytes: nil
        )

        let status: RunStatus = stagePartial == nil ? .success : .partial
        return UpscalerRun(
            clipID: clip.id,
            inputResolution: lrResolution,   // LR fed to the model (HR÷scale)
            outputResolution: outputResolution,
            scaleFactor: scale,
            frameCount: frameCount,
            speed: speed,
            quality: quality,
            memory: memory,
            textMetrics: nil,
            status: status,
            failureReason: stagePartial,
            backend: backendLabel
        )
    }

    /// Back-compat shim: the original Phase A.2 entry point keyed by a
    /// freeform `tier: String`. Routes `"playback"` → `.efrlfn` (the
    /// post-ADR-0006 default) so the existing CLI default path still
    /// works. `"export"` / `"signage"` continue to surface the old
    /// Phase C/D-scope `.failed` reason — those tiers don't have a
    /// real runner yet.
    public func runUpscalerPass(
        tier: String,
        clip: CorpusClip
    ) async -> UpscalerRun {
        if tier == "playback" {
            // Post-C.4 default is SRVGGNetCompact-general (ADR-0008), not
            // EfRLFN — matches PlaybackUpscaler.Backend.defaultGeneral.
            return await runUpscalerPass(backend: .srvggnetGeneral, scale: 4, clip: clip)
        }
        let inputRes = clip.resolution
        let outputRes = Self.scaleResolution(inputRes, factor: 2)
        return UpscalerRun(
            clipID: clip.id,
            inputResolution: inputRes,
            outputResolution: outputRes,
            scaleFactor: 2,
            status: .failed,
            failureReason: "ForgeUpscaler \(tier) tier not yet wired (export/signage; playback uses runUpscalerPass(backend:scale:clip:))"
        )
    }

    /// Drain loop for the upscaler pass — analogous to `drainDecoder`
    /// but pipes the decoded frame through `tier.upscale(_:)` instead
    /// of the optimizer chain. Returns nil on clean EOF or a string
    /// describing why the loop aborted early.
    private func drainUpscaler(
        decoder: any VideoDecoding,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        tier: PlaybackTier,
        frameRate: Double,
        perFrameMs: inout [Double],
        firstFrameMs: inout Double,
        frameCount: inout Int,
        peakResidentBytes: inout UInt64,
        psnrSum: inout Double,
        ssimSum: inout Double,
        psnrCount: inout Int,
        ssimCount: inout Int
    ) async -> String? {
        var abortReason: String? = nil
        let qm = QualityMeasure()
        let qualityStride = 30

        while true {
            let frame: DecodedVideoFrame?
            do {
                frame = try await decoder.decodeNextVideoFrame()
            } catch {
                abortReason = "decode aborted at frame \(frameCount): \(error)"
                break
            }
            guard let video = frame else { break }

            let clock = ContinuousClock()
            let start = clock.now
            let processed: CVPixelBuffer
            do {
                processed = try await tier.upscale(video.pixelBuffer)
            } catch {
                abortReason = "upscale failed at frame \(frameCount): \(error)"
                break
            }
            let elapsed = clock.now - start
            let ms = Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1000.0
            perFrameMs.append(ms)
            if frameCount == 0 {
                firstFrameMs = ms
            }
            frameCount += 1

            // Quality sampling — DELIBERATELY NOT COMPUTED HERE.
            //
            // PSNR/SSIM are pixel-level metrics that require matching-
            // dimension reference and test buffers. In the upscaler pass
            // the input is source resolution and the SR output is N× that,
            // so no direct same-shape comparison is available.
            //
            // We do NOT have ground truth at the SR output resolution
            // (the corpus clips are the highest-fidelity sources we have),
            // so the only mathematically valid pixel-level alternatives —
            //
            //   • PSNR/SSIM(SR_output, bicubic_upscaled_source)
            //     measures "similarity to bicubic baseline" which inverts
            //     the desired ranking (we WANT SR to differ from bicubic).
            //
            //   • PSNR/SSIM(downscale(SR_output), source)
            //     measures roundtrip-information-preservation. Correct SR
            //     networks score ~∞ regardless of perceived quality, so
            //     this can't rank backends — only catch broken SR.
            //
            // — are not useful for the Phase C.4 ship criterion ranking.
            // VMAF handles cross-resolution comparison properly (rescales
            // internally) and is what ADR-0006's ship criterion measures
            // against. The VMAF call outside this loop fills the
            // `quality.vmaf` field when --skip-vmaf is OFF. When --skip-vmaf
            // is on (smoke / fast-iteration runs), `quality` carries no
            // pixel-level metrics and the report shows nil; that's honest
            // signal, not a measurement error.
            //
            // Suppress the unused-variable warnings — the parameter list
            // stays for symmetry with drainDecoder, where these accumulators
            // ARE used because the optimizer-pass output is same-resolution
            // as the input.
            _ = qm
            _ = qualityStride
            _ = psnrSum; _ = ssimSum; _ = psnrCount; _ = ssimCount

            if frameCount % 30 == 0 {
                let resident = currentResidentBytes()
                if resident > peakResidentBytes {
                    peakResidentBytes = resident
                }
            }

            let pts = CMTime(value: CMTimeValue(Double(frameCount - 1) * 600.0 / max(frameRate, 1.0)),
                             timescale: 600)
            var appended = false
            let backoffsMs: [UInt64] = [0, 5, 20, 50, 100, 200]
            for backoff in backoffsMs {
                if backoff > 0 {
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000)
                }
                if input.isReadyForMoreMediaData {
                    if adaptor.append(processed, withPresentationTime: pts) {
                        appended = true
                        break
                    }
                }
            }
            if !appended {
                abortReason = "encode stalled at frame \(frameCount): adaptor.append returned false or writer never ready"
                break
            }
        }

        let resident = currentResidentBytes()
        if resident > peakResidentBytes {
            peakResidentBytes = resident
        }
        return abortReason
    }

    // MARK: - Decode/encode drain loop

    /// Drain the decoder, push video frames through the optional chain,
    /// hand them to the direct AVAssetWriterInputPixelBufferAdaptor,
    /// and update timing/memory accumulators in-place. Returns nil on
    /// clean EOF or a string describing why the loop aborted early.
    private func drainDecoder(
        decoder: any VideoDecoding,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        chain: (any FrameProcessor)?,
        frameRate: Double,
        perFrameMs: inout [Double],
        firstFrameMs: inout Double,
        frameCount: inout Int,
        peakResidentBytes: inout UInt64,
        psnrSum: inout Double,
        ssimSum: inout Double,
        psnrCount: inout Int,
        ssimCount: inout Int,
        clip: CorpusClip
    ) async -> String? {
        var abortReason: String? = nil
        let qm = QualityMeasure()
        // Sample quality every ~30 frames to keep the loop cheap. PSNR/
        // SSIM cost scales with frame size and we don't need every frame.
        let qualityStride = 30
        // Approximate per-frame duration in CMTime ticks if the decoder
        // doesn't provide one. NativeEncoder requires a duration.
        let fallbackDuration = CMTime(seconds: 1.0 / max(frameRate, 1.0), preferredTimescale: 600)

        while true {
            // Decode the next video frame. We use the video-only path
            // here — benchmarks don't need audio in the output, and
            // skipping audio reduces noise in the per-frame timing.
            let frame: DecodedVideoFrame?
            do {
                frame = try await decoder.decodeNextVideoFrame()
            } catch {
                abortReason = "decode aborted at frame \(frameCount): \(error)"
                break
            }
            guard let video = frame else { break }

            let clock = ContinuousClock()
            let start = clock.now
            let processed = chain?.process(video.pixelBuffer) ?? video.pixelBuffer
            let elapsed = clock.now - start
            let ms = Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1000.0
            perFrameMs.append(ms)
            if frameCount == 0 {
                firstFrameMs = ms
            }
            frameCount += 1

            // Quality sampling (cheap, periodic) on luma plane.
            if frameCount % qualityStride == 1 {
                if let psnr = try? qm.psnr(reference: video.pixelBuffer, test: processed),
                   psnr.isFinite {
                    psnrSum += psnr
                    psnrCount += 1
                }
                if let ssim = try? qm.ssim(reference: video.pixelBuffer, test: processed) {
                    ssimSum += ssim
                    ssimCount += 1
                }
            }

            // Memory probe every 30 frames; cheap mach call, but no need
            // to do it per-frame.
            if frameCount % 30 == 0 {
                let resident = currentResidentBytes()
                if resident > peakResidentBytes {
                    peakResidentBytes = resident
                }
            }

            // Hand the processed buffer to the encoder. We always
            // synthesize a PTS from the frame index — the decoder's
            // best_effort_timestamp can start at non-zero values that
            // the writer (configured with startSession(atSourceTime:
            // .zero)) won't accept, and PTS jitter from the decoder
            // can cause silent frame drops. Use a 600-timescale to
            // match common video timebases.
            let pts = CMTime(value: CMTimeValue(Double(frameCount - 1) * 600.0 / max(frameRate, 1.0)),
                             timescale: 600)
            let duration = CMTime(value: CMTimeValue(600.0 / max(frameRate, 1.0)), timescale: 600)
            _ = video.duration  // unused now; kept for future use
            _ = fallbackDuration
            // Push to the writer's pixel-buffer adaptor. The writer is
            // video-only (no audio input) so it drains continuously.
            // If the input isn't ready, we yield + wait briefly (the
            // writer's serial queue runs on a separate thread).
            var appended = false
            let backoffsMs: [UInt64] = [0, 5, 20, 50, 100, 200]
            for backoff in backoffsMs {
                if backoff > 0 {
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000)
                }
                if input.isReadyForMoreMediaData {
                    if adaptor.append(processed, withPresentationTime: pts) {
                        appended = true
                        break
                    }
                }
            }
            if !appended {
                abortReason = "encode stalled at frame \(frameCount): adaptor.append returned false or writer never ready"
                break
            }
            _ = duration  // (reserved; AVAssetWriterInputPixelBufferAdaptor derives duration from PTS deltas)
            _ = clip
        }

        // Final memory snapshot — useful even for short clips that don't
        // hit the periodic probe.
        let resident = currentResidentBytes()
        if resident > peakResidentBytes {
            peakResidentBytes = resident
        }

        _ = clip
        return abortReason
    }

    // MARK: - Resident memory

    /// Read the current process's resident-set size in bytes from
    /// `mach_task_basic_info`. Returns 0 on failure.
    private func currentResidentBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size /
                                           MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          reboundPtr,
                          &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return info.resident_size
        #else
        return 0
        #endif
    }

    // MARK: - Helpers

    /// Map the report's lowercase `OptimizerRun.OptimizationLevel` to
    /// FormatBridge's TitleCase `OptimizationLevel`. Two parallel enums
    /// exist by design — schema uses lowercase, the app uses TitleCase.
    static func mapToFormatBridgeLevel(_ level: OptimizerRun.OptimizationLevel) -> OptimizationLevel {
        switch level {
        case .off: return .off
        case .light: return .light
        case .balanced: return .balanced
        case .aggressive: return .aggressive
        case .maximum: return .maximum
        }
    }

    /// Pick an encoder quality preset for the given optimization level.
    /// The mapping is intentionally simple — heavier optimization gets
    /// higher quality on the encode side so the optimization-vs-codec
    /// effect dominates the report.
    static func qualityPreset(for level: OptimizerRun.OptimizationLevel) -> QualityPreset {
        switch level {
        case .off: return .medium
        case .light: return .medium
        case .balanced: return .high
        case .aggressive: return .high
        case .maximum: return .maximum
        }
    }

    static func qualityPresetName(for level: OptimizerRun.OptimizationLevel) -> String {
        switch qualityPreset(for: level) {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .maximum: return "maximum"
        }
    }

    /// Parse "WIDTHxHEIGHT" → (Int, Int). Returns (0, 0) on malformed
    /// input.
    static func parseResolution(_ s: String) -> (Int, Int) {
        let parts = s.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else {
            return (0, 0)
        }
        return (w, h)
    }

    /// Scale "WIDTHxHEIGHT" by `factor`. Returns "0x0" on malformed
    /// input — matches `BenchmarkSuite.scale2x` behavior.
    static func scaleResolution(_ s: String, factor: Int) -> String {
        let (w, h) = parseResolution(s)
        guard w > 0, h > 0 else { return "0x0" }
        return "\(w * factor)x\(h * factor)"
    }

    /// Linear-interpolation percentile on a *sorted* ascending array.
    /// Returns 0 on empty input. Matches numpy's default (linear).
    static func percentile<T: RandomAccessCollection>(_ sorted: T, _ q: Double) -> Double
    where T.Element == Double, T.Index == Int {
        guard !sorted.isEmpty else { return 0.0 }
        if sorted.count == 1 { return sorted[sorted.startIndex] }
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Int(pos.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = pos - Double(lo)
        return sorted[lo] * (1.0 - frac) + sorted[hi] * frac
    }

    /// Population stddev. Returns 0 on empty input.
    static func stddev<T: RandomAccessCollection>(values: T, mean: Double) -> Double
    where T.Element == Double {
        guard !values.isEmpty else { return 0.0 }
        var sumSq = 0.0
        for v in values {
            let d = v - mean
            sumSq += d * d
        }
        return (sumSq / Double(values.count)).squareRoot()
    }
}
