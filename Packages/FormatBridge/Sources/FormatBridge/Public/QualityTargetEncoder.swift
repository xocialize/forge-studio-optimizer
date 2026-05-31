import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// VMAF-targeted constant-quality encoder (Step 1, ADR-0013/0014).
///
/// Ties the [`QualityTargetSearch`] algorithm to the Step-0 VideoToolbox encoder
/// ([`VideoToolboxEncoderImpl`]) and an injected [`QualityScoring`] (real VMAF
/// lives in the runner/CLI). Given the frames to ship and a pristine `reference`
/// clip of those same frames, it finds the lowest `constantQuality` that clears
/// the perceptual target via sample encodes, then performs the final encode at
/// that quality.
///
/// This increment searches **per-title** (each probe encodes the supplied
/// frames). Per-shot search and sub-range "sample" probes are the next step
/// (#50) — the search/scorer/encoder seams here are reused unchanged.
public final class VideoToolboxQualityTargetEncoder: Sendable {

    private let scorer: any QualityScoring
    private let search: QualityTargetSearch

    public init(scorer: any QualityScoring, search: QualityTargetSearch) {
        self.scorer = scorer
        self.search = search
    }

    /// Encode `frames` at the lowest constant-quality that meets the target.
    ///
    /// - Parameters:
    ///   - frames: the (e.g. NAFNet-processed) frames to ship, in order. Must be
    ///     non-empty and uniformly sized.
    ///   - reference: a pristine clip of the same frames — the VMAF reference.
    ///   - output: destination for the final encode.
    ///   - settings: codec / frame-rate / etc. `resolution` is taken from the
    ///     frames; `constantQuality` is overridden by the search result.
    /// - Returns: the search outcome (chosen quality, achieved score, probes).
    @discardableResult
    public func encode(frames: [CVPixelBuffer],
                       reference: URL,
                       output: URL,
                       settings: VideoEncoderSettings) async throws -> QualityTargetResult {
        guard let first = frames.first else {
            throw QualityTargetError.noFrames
        }
        let w = CVPixelBufferGetWidth(first)
        let h = CVPixelBufferGetHeight(first)

        // Effective settings: lock resolution to the frames; quality is the knob
        // the search drives, so it's filled in per-probe.
        func effectiveSettings(quality: Float) -> VideoEncoderSettings {
            VideoEncoderSettings(codec: settings.codec,
                                 quality: settings.quality,
                                 resolution: .custom(width: w, height: h),
                                 frameRate: settings.frameRate,
                                 hardwareAcceleration: settings.hardwareAcceleration,
                                 constantQuality: quality)
        }

        // Per-encode temp dir so concurrent encodes never clobber each other's
        // probe files (each probe filename still encodes its quality for tracing).
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtqt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        var probeCount = 0
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Each probe: encode all frames at `q`, score against the reference.
        let result = try await search.search { q in
            let probeURL = tmpDir.appendingPathComponent("probe-\(probeCount)-\(Int(q * 1000)).mp4")
            probeCount += 1
            try await Self.encodeFrames(frames, to: probeURL, settings: effectiveSettings(quality:q))
            return try await self.scorer.score(reference: reference, distorted: probeURL)
        }

        // Final encode at the chosen quality.
        try await Self.encodeFrames(frames, to: output, settings: effectiveSettings(quality:result.quality))
        return result
    }

    // MARK: - Frame encode

    /// Encode an in-memory frame array to `output` via the Step-0 encoder.
    private static func encodeFrames(_ frames: [CVPixelBuffer],
                                     to output: URL,
                                     settings: VideoEncoderSettings) async throws {
        let fps = settings.outputFrameRate > 0 ? settings.outputFrameRate : 30.0
        let timescale: Int32 = 600
        let frameDur = CMTime(value: Int64(Double(timescale) / fps), timescale: timescale)

        let encoder = VideoToolboxEncoderImpl()
        try encoder.configure(output: output, videoSettings: settings, audioSettings: nil)
        for (i, frame) in frames.enumerated() {
            let pts = CMTimeMultiply(frameDur, multiplier: Int32(i))
            try encoder.appendVideoFrame(frame, at: pts, duration: frameDur)
        }
        try await encoder.finish()
    }

    public enum QualityTargetError: Error, CustomStringConvertible {
        case noFrames
        public var description: String {
            switch self {
            case .noFrames: return "VideoToolboxQualityTargetEncoder: no frames to encode"
            }
        }
    }
}
