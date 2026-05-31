//
// FFmpegVMAFScorer.swift
// ForgeOptimizer / Benchmark
//
// Concrete `QualityScoring` (FormatBridge seam) backing the VMAF-targeted
// encode path (Step 1, ADR-0013/0014) with real VMAF via ffmpeg's libvmaf.
//
// Lives in the benchmark/runner layer — NOT in FormatBridge — because it shells
// out to the `ffmpeg` binary (FormatBridge deliberately avoids binary
// shell-outs and does not link libvmaf). It simply adapts the existing,
// already-tested `QualityMeasure.vmaf(referenceURL:testURL:)` to the protocol
// the search/encoder consume.
//

import FormatBridge
import Foundation

/// Scores `distorted` against `reference` with real VMAF (ffmpeg `libvmaf`).
public struct FFmpegVMAFScorer: QualityScoring {

    private let ffmpegPath: String
    private let measure = QualityMeasure()

    /// - Parameter ffmpegPath: an ffmpeg binary with `libvmaf` compiled in.
    ///   Defaults to the first existing candidate (ffmpeg-full per ADR-0002,
    ///   then a plain Homebrew/system ffmpeg — Homebrew's `ffmpeg` ≥ 6 ships
    ///   libvmaf).
    public init(ffmpegPath: String? = nil) {
        self.ffmpegPath = ffmpegPath ?? Self.resolveFFmpeg()
    }

    public func score(reference: URL, distorted: URL) async throws -> Double {
        // QualityMeasure takes (reference, test) and maps test→input0,
        // reference→input1, which is the libvmaf convention.
        try await measure.vmaf(referenceURL: reference, testURL: distorted, ffmpegPath: ffmpegPath)
    }

    /// The resolved ffmpeg binary path (exposed for diagnostics/tests).
    public var resolvedFFmpegPath: String { ffmpegPath }

    /// Prefer the ffmpeg-full dev toolchain (ADR-0002); fall back to a plain
    /// Homebrew/system ffmpeg that has libvmaf compiled in.
    public static func resolveFFmpeg() -> String {
        let candidates = [
            "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        let fm = FileManager.default
        return candidates.first { fm.fileExists(atPath: $0) } ?? candidates[0]
    }
}
