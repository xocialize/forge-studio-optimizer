import CoreVideo
import Foundation

// Quality-targeted still optimization (PRD §6) — the still analog of the video
// VMAF-target search. The metric is INJECTED (`StillQualityScoring`), never linked
// into the bridge, exactly like libvmaf on the video side: ImageBridge ships the
// search; the runner supplies SSIMULACRA2 (full-ref) or the SigLIP2 NR-IQA head
// (no-ref, the signage default). Applies to lossy formats (JPEG/HEIC/AVIF/WebP);
// PNG is already handled losslessly by oxipng.

/// Perceptual quality of an encoded candidate. `reference` is the pristine
/// original — full-reference metrics (SSIMULACRA2) use it; no-reference metrics
/// (SigLIP2 NR-IQA) ignore it. Higher = better; the search targets a floor.
public protocol StillQualityScoring: Sendable {
    func score(reference: CVPixelBuffer, distorted: CVPixelBuffer) -> Double
}

/// Search configuration — binary-search the encoder quality knob for the smallest
/// file clearing the floor.
public struct StillQualityTargetSearch: Sendable {
    public let targetScore: Double            // perceptual floor (metric-dependent units)
    public let qualityRange: ClosedRange<Double>
    public let slack: Double                  // accept score >= target - slack
    public let maxProbes: Int

    public init(targetScore: Double, qualityRange: ClosedRange<Double> = 0.3 ... 1.0,
                slack: Double = 0.0, maxProbes: Int = 8) {
        self.targetScore = targetScore
        self.qualityRange = qualityRange
        self.slack = slack
        self.maxProbes = maxProbes
    }
}

public struct StillTargetResult: Sendable {
    public let quality: Double
    public let achievedScore: Double
    public let metTarget: Bool
    public let bytes: Int
    public let probeCount: Int
}

/// Composes an encoder + decoder + injected scorer into a VMAF-target-style
/// search: the smallest lossy encode that still clears the perceptual floor.
public final class StillQualityTargetEncoder: @unchecked Sendable {

    private let encoder: any StillEncoding
    private let decoder: any StillDecoding
    private let scorer: any StillQualityScoring
    private let search: StillQualityTargetSearch

    public init(encoder: any StillEncoding, decoder: any StillDecoding,
                scorer: any StillQualityScoring, search: StillQualityTargetSearch) {
        self.encoder = encoder
        self.decoder = decoder
        self.scorer = scorer
        self.search = search
    }

    /// Encode `original` to `url` at the lowest quality that clears the floor.
    public func encode(original: CVPixelBuffer, format: StillOutputFormat,
                       metadata: StillMetadata?, to url: URL) throws -> StillTargetResult {
        precondition(format != .png, "PNG is lossless — use the oxipng path, not the quality search")
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".sqt-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Lowest quality (smallest file) with score >= floor. Lower q = smaller +
        // lower score, so: meets floor → search lower; misses → search higher.
        var lo = search.qualityRange.lowerBound
        var hi = search.qualityRange.upperBound
        var best: (q: Double, score: Double, bytes: Int)?
        var probes = 0
        let floor = search.targetScore - search.slack

        while probes < search.maxProbes, hi - lo > 0.02 {
            let q = (lo + hi) / 2
            let s = try probe(original: original, format: format, metadata: metadata, quality: q, tmp: tmp)
            probes += 1
            if s.score >= floor { best = (q, s.score, s.bytes); hi = q }
            else { lo = q }
        }

        let chosen = best?.q ?? search.qualityRange.upperBound   // none met → max quality (best effort)
        try encoder.encode(original,
                           settings: StillEncoderSettings(format: format, quality: chosen,
                                                          stripMetadata: metadata == nil),
                           metadata: metadata, to: url)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return StillTargetResult(quality: chosen, achievedScore: best?.score ?? 0,
                                 metTarget: best != nil, bytes: bytes, probeCount: probes)
    }

    private func probe(original: CVPixelBuffer, format: StillOutputFormat, metadata: StillMetadata?,
                       quality: Double, tmp: URL) throws -> (score: Double, bytes: Int) {
        try encoder.encode(original,
                           settings: StillEncoderSettings(format: format, quality: quality,
                                                          stripMetadata: metadata == nil),
                           metadata: metadata, to: tmp)
        let (frames, _) = try decoder.decode(url: tmp)
        guard let cand = frames.first else { throw ImageBridgeError.decodeFailed("probe decode") }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        return (scorer.score(reference: original, distorted: cand), bytes)
    }
}
