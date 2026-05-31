import Foundation

/// Outcome of a VMAF-targeted quality search.
public struct QualityTargetResult: Sendable, Equatable {
    /// The chosen constant-quality knob in `[0, 1]` — feed to
    /// `VideoEncoderSettings.constantQuality`. The *lowest* quality (smallest
    /// file) that still met the perceptual target.
    public let quality: Float
    /// The perceptual score (VMAF convention) achieved at `quality`.
    public let achievedScore: Double
    /// Whether `achievedScore` met the target within slack. `false` means even
    /// the maximum quality could not reach the target — `quality` is then the
    /// ceiling (best effort).
    public let metTarget: Bool
    /// Number of sample encodes performed (cost of the search).
    public let probeCount: Int

    public init(quality: Float, achievedScore: Double, metTarget: Bool, probeCount: Int) {
        self.quality = quality
        self.achievedScore = achievedScore
        self.metTarget = metTarget
        self.probeCount = probeCount
    }
}

/// VMAF-targeted constant-quality search (Step 1, ADR-0014).
///
/// Finds the **lowest** VideoToolbox constant-quality value whose perceptual
/// score still clears a target floor — i.e. the smallest file at a guaranteed
/// quality, which is the whole product claim. This is the "sample-encode"
/// approach (ab-av1 style): a handful of short probe encodes via binary search
/// instead of a full sweep, exploiting that perceptual score is (weakly)
/// monotonic in the quality knob.
///
/// Pure algorithm — the `probe` closure does the actual encode-and-score, so
/// this type has no dependency on the encoder or VMAF and is unit-testable with
/// a synthetic oracle.
public struct QualityTargetSearch: Sendable {
    /// Target perceptual score (e.g. VMAF 95; 93 for the "smaller" tier).
    public var targetScore: Double
    /// Accept a probe whose score is `>= targetScore - slack` (avoids chasing
    /// the last fraction of a VMAF point across many extra encodes).
    public var slack: Double
    /// Quality knob range to search. Default floor is `0.1`, not `0` — VT's very
    /// bottom is rarely worth probing for signage.
    public var qualityRange: ClosedRange<Float>
    /// Stop bisecting once the bracket is this narrow.
    public var resolution: Float
    /// Hard cap on probe encodes (cost safety). Includes the two bracket probes.
    public var maxProbes: Int

    public init(targetScore: Double,
                slack: Double = 0.5,
                qualityRange: ClosedRange<Float> = 0.1...1.0,
                resolution: Float = 0.03,
                maxProbes: Int = 8) {
        precondition(maxProbes >= 2, "need at least the two bracket probes")
        self.targetScore = targetScore
        self.slack = slack
        self.qualityRange = qualityRange
        self.resolution = resolution
        self.maxProbes = maxProbes
    }

    /// Search for the lowest acceptable quality.
    ///
    /// - Parameter probe: encodes a sample at the given quality and returns its
    ///   perceptual score. Assumed (weakly) monotonic increasing in quality.
    /// - Returns: the chosen quality and the score it achieved.
    public func search(probe: (Float) async throws -> Double) async rethrows -> QualityTargetResult {
        let accept = targetScore - slack
        var lo = qualityRange.lowerBound
        var hi = qualityRange.upperBound
        var probes = 0

        // Bracket the ceiling: if even max quality can't reach the target, return
        // it as best effort (the caller may downscale resolution or accept it).
        let hiScore = try await probe(hi); probes += 1
        if hiScore < accept {
            return QualityTargetResult(quality: hi, achievedScore: hiScore,
                                       metTarget: false, probeCount: probes)
        }

        // Bracket the floor: if min quality already clears the target, take it —
        // maximum savings, no search needed.
        let loScore = try await probe(lo); probes += 1
        if loScore >= accept {
            return QualityTargetResult(quality: lo, achievedScore: loScore,
                                       metTarget: true, probeCount: probes)
        }

        // Invariant: probe(lo) < accept <= probe(hi). Bisect, tracking the lowest
        // acceptable quality seen so far.
        var bestQ = hi
        var bestScore = hiScore
        while hi - lo > resolution && probes < maxProbes {
            let mid = (lo + hi) / 2
            let s = try await probe(mid); probes += 1
            if s >= accept {
                hi = mid; bestQ = mid; bestScore = s   // acceptable → push for smaller
            } else {
                lo = mid                                // too low → need more quality
            }
        }
        return QualityTargetResult(quality: bestQ, achievedScore: bestScore,
                                   metTarget: true, probeCount: probes)
    }
}
