import Foundation

/// Perceptual-quality scorer for the VMAF-targeted encode path (Step 1, ADR-0014).
///
/// Deliberately a seam: FormatBridge ships ffmpeg via the libav C API and does
/// **not** link `libvmaf`, so the real VMAF measurement (ffmpeg `libvmaf` filter,
/// or a future native scorer) is *injected* by the caller — typically the
/// benchmark runner / CLI, which already shells out to the `ffmpeg` binary. This
/// keeps the search algorithm and the encoder free of any VMAF dependency and
/// makes both unit-testable with a synthetic scorer.
public protocol QualityScoring: Sendable {
    /// Perceptual score (VMAF convention: 0–100, higher is better) of the
    /// `distorted` clip against the pristine `reference`.
    ///
    /// The two clips are assumed frame-aligned and same-dimensioned (the
    /// VMAF-targeted encoder encodes the very frames the `reference` covers).
    func score(reference: URL, distorted: URL) async throws -> Double
}
