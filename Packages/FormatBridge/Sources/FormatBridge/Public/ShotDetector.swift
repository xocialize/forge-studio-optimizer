import Foundation

/// Shot-boundary detector for per-shot VMAF-targeted encoding (Step 2, #50).
///
/// Per-shot rate control beats per-title (Vimeo's approach) because an easy shot
/// can use a lower quality than a hard one while both clear the same VMAF floor —
/// the research puts the extra savings at ~10–20% over per-title at equal quality.
/// That requires knowing where the cuts are.
///
/// Pure algorithm over per-frame **signatures** (e.g. normalised luma
/// histograms): a hard cut changes the histogram far more than within-shot
/// motion does, so a thresholded L1 distance between consecutive signatures
/// locates cuts robustly. Decoupled from pixel access so it's unit-testable with
/// synthetic signatures.
public struct ShotDetector: Sendable {

    /// L1 distance (0…1) above which consecutive frames are a cut.
    public var threshold: Double
    /// Minimum frames per shot — a cut closer than this to the previous one is
    /// suppressed (avoids splitting on flashes / 1-frame glitches).
    public var minShotFrames: Int

    public init(threshold: Double = 0.35, minShotFrames: Int = 12) {
        self.threshold = threshold
        self.minShotFrames = minShotFrames
    }

    /// L1 distance between two equal-length, non-negative signatures, normalised
    /// to 0…1 (assumes each signature sums to ~1, i.e. a normalised histogram).
    public static func distance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0.0
        for i in a.indices { sum += abs(Double(a[i]) - Double(b[i])) }
        return min(1.0, sum / 2.0)   // each histogram sums to 1 → L1 ∈ [0, 2]
    }

    /// Frame indices where a new shot starts (always includes 0).
    public func boundaries(signatures: [[Float]]) -> [Int] {
        guard !signatures.isEmpty else { return [] }
        var starts = [0]
        var lastCut = 0
        for i in 1 ..< signatures.count {
            let d = Self.distance(signatures[i - 1], signatures[i])
            if d > threshold && (i - lastCut) >= minShotFrames {
                starts.append(i)
                lastCut = i
            }
        }
        return starts
    }

    /// Contiguous shot ranges covering `0 ..< signatures.count`.
    public func shots(signatures: [[Float]]) -> [Range<Int>] {
        let starts = boundaries(signatures: signatures)
        guard !starts.isEmpty else { return [] }
        let n = signatures.count
        var ranges: [Range<Int>] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1] : n
            ranges.append(s ..< end)
        }
        return ranges
    }
}
