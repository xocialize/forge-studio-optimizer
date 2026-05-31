//
// FFmpegVMAFScorerTests.swift
// ForgeOptimizer / Benchmark
//
// Exercises the real ffmpeg libvmaf path through the `QualityScoring` adapter.
// Guarded on an ffmpeg-with-libvmaf being present so it no-ops on bare CI.
//

import Testing
import Foundation
@testable import ForgeOptimizer

@Suite("FFmpegVMAFScorer (Step 1 VMAF seam)")
struct FFmpegVMAFScorerTests {

    /// True when the resolved ffmpeg exists and advertises the libvmaf filter.
    static var ffmpegHasVMAF: Bool {
        let path = FFmpegVMAFScorer.resolveFFmpeg()
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-hide_banner", "-filters"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return s.contains("libvmaf")
    }

    /// Make a 1 s 256×256 clip via ffmpeg lavfi. `extraOut` injects a quality
    /// knob / filter. Uses the always-built-in mpeg4 encoder (no libx264 dep).
    private func makeClip(_ ffmpeg: String, to url: URL, vf: String?, qv: Int) throws {
        try? FileManager.default.removeItem(at: url)
        var args = ["-hide_banner", "-y",
                    "-f", "lavfi", "-i", "testsrc2=size=256x256:rate=30:duration=1"]
        if let vf { args += ["-vf", vf] }
        args += ["-c:v", "mpeg4", "-q:v", String(qv), url.path]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        p.standardError = Pipe(); p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.fixture("ffmpeg failed to build \(url.lastPathComponent)")
        }
    }

    enum Failure: Error { case fixture(String) }

    @Test("real VMAF: identical ≈ 100, degraded is lower and in (0,100]",
          .enabled(if: FFmpegVMAFScorerTests.ffmpegHasVMAF))
    func realVMAF() async throws {
        let ffmpeg = FFmpegVMAFScorer.resolveFFmpeg()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmaf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ref = dir.appendingPathComponent("ref.mp4")
        let degraded = dir.appendingPathComponent("degraded.mp4")
        // Reference: high-quality. Degraded: same content, blurred + low quality.
        try makeClip(ffmpeg, to: ref, vf: nil, qv: 2)
        try makeClip(ffmpeg, to: degraded, vf: "boxblur=4:1", qv: 28)

        let scorer = FFmpegVMAFScorer()

        // Self-comparison ≈ 100 (identical decoded frames).
        let same = try await scorer.score(reference: ref, distorted: ref)
        #expect(same >= 95.0)

        // Degraded clip scores meaningfully lower, still a valid VMAF.
        let worse = try await scorer.score(reference: ref, distorted: degraded)
        #expect(worse > 0.0 && worse <= 100.0)
        #expect(worse < same - 5.0)
    }
}
