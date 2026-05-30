//
// QualityMeasure.swift
// ForgeOptimizer / Benchmark
//
// Per-frame and per-clip quality metrics consumed by the benchmark
// report's `QualityMetrics` block.
//
// - PSNR: pure-Swift per-pixel MSE on `CVPixelBuffer` planar luma; no
//   external dependency.
// - SSIM: simplified single-scale SSIM on luma channel. Pure Swift
//   (vImage's MS-SSIM helper isn't in the public API on every macOS
//   version, and the goal here is portability across CI runners more
//   than peak fidelity).
// - VMAF: subprocess to /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg with
//   `-lavfi libvmaf` per ADR 0002 (dev toolchain, not runtime).
// - LPIPS: stub returning 0; a real LPIPS implementation needs a
//   convnet on each frame, deferred to Phase B per task scope.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import CoreVideo
import Foundation

public enum QualityMeasureError: Error, Sendable, CustomStringConvertible {
    case dimensionMismatch(refSize: CGSize, testSize: CGSize)
    case pixelBufferLockFailed
    case ffmpegMissing(String)
    case ffmpegFailed(String)
    case vmafParseFailed(String)

    public var description: String {
        switch self {
        case .dimensionMismatch(let r, let t):
            return "Quality measure dimension mismatch: ref \(r) vs test \(t)"
        case .pixelBufferLockFailed:
            return "Failed to lock pixel buffer base address"
        case .ffmpegMissing(let path):
            return "ffmpeg-full binary not found at \(path)"
        case .ffmpegFailed(let detail):
            return "ffmpeg subprocess failed: \(detail)"
        case .vmafParseFailed(let detail):
            return "Failed to parse VMAF score from ffmpeg output: \(detail)"
        }
    }
}

/// Pure-function quality metrics. No internal state.
public struct QualityMeasure: Sendable {

    public init() {}

    // MARK: - PSNR

    /// Pure-Swift PSNR on the luma channel of two CVPixelBuffers.
    ///
    /// Both buffers must have the same dimensions and a planar YUV
    /// pixel format (or a packed format where channel 0 is luma).
    /// Returns dB; +∞ when frames are identical.
    public func psnr(reference: CVPixelBuffer, test: CVPixelBuffer) throws -> Double {
        let mse = try meanSquaredError(reference: reference, test: test)
        return Self.psnr(mse: mse)
    }

    /// Convert an MSE on the [0, 255] domain into a PSNR in dB.
    static func psnr(mse: Double) -> Double {
        guard mse > 0 else { return .infinity }
        let maxValue: Double = 255.0
        return 20.0 * log10(maxValue) - 10.0 * log10(mse)
    }

    // MARK: - SSIM

    /// Simplified single-scale SSIM on the luma channel. Uses the
    /// reference Wang et al. 2004 formulation with global means rather
    /// than a sliding 8×8 window — adequate for the benchmark harness's
    /// regression-detection use case but not a paper-faithful SSIM.
    /// Returns a value in [0, 1].
    public func ssim(reference: CVPixelBuffer, test: CVPixelBuffer) throws -> Double {
        try ensureSameDimensions(reference, test)
        let (refPixels, testPixels) = try lumaPixels(reference: reference, test: test)

        let n = Double(refPixels.count)
        guard n > 0 else { return 1.0 }

        var sumR = 0.0
        var sumT = 0.0
        for i in 0..<refPixels.count {
            sumR += Double(refPixels[i])
            sumT += Double(testPixels[i])
        }
        let muR = sumR / n
        let muT = sumT / n

        var sigR2 = 0.0
        var sigT2 = 0.0
        var sigRT = 0.0
        for i in 0..<refPixels.count {
            let dr = Double(refPixels[i]) - muR
            let dt = Double(testPixels[i]) - muT
            sigR2 += dr * dr
            sigT2 += dt * dt
            sigRT += dr * dt
        }
        sigR2 /= n
        sigT2 /= n
        sigRT /= n

        let L = 255.0
        let k1 = 0.01
        let k2 = 0.03
        let c1 = (k1 * L) * (k1 * L)
        let c2 = (k2 * L) * (k2 * L)

        let numerator = (2 * muR * muT + c1) * (2 * sigRT + c2)
        let denominator = (muR * muR + muT * muT + c1) * (sigR2 + sigT2 + c2)
        guard denominator > 0 else { return 1.0 }
        let raw = numerator / denominator
        // Clamp to [0, 1].
        return max(0.0, min(1.0, raw))
    }

    // MARK: - VMAF

    /// Path to the ffmpeg-full binary (per ADR 0002). Override via
    /// `vmaf(..., ffmpegPath:)`.
    public static let defaultFFmpegPath = "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"

    /// Compute VMAF for `test` against `reference` by shelling out to
    /// ffmpeg-full's libvmaf filter. Both URLs must point to decodable
    /// video files (any format ffmpeg can read).
    public func vmaf(
        referenceURL: URL,
        testURL: URL,
        ffmpegPath: String = QualityMeasure.defaultFFmpegPath
    ) async throws -> Double {
        let fm = FileManager.default
        guard fm.fileExists(atPath: ffmpegPath) else {
            throw QualityMeasureError.ffmpegMissing(ffmpegPath)
        }

        // libvmaf requires both inputs at identical dimensions, and it does
        // NOT auto-rescale. Input 0 is test (distorted), input 1 is the
        // reference. `scale2ref` scales the reference ([1:v]) to the test's
        // ([0:v]) dimensions with bicubic before libvmaf — so a few-pixel
        // rounding difference between the SR output and the original ground
        // truth (e.g. 1080/4*4 vs 1080) is absorbed rather than throwing
        // "failed to configure input pad on Parsed_libvmaf". For the proper
        // SR benchmark (downscale → SR → compare-to-original) test and
        // reference are already ~equal resolution, so this is a no-op /
        // sub-pixel correction, not a methodology-altering rescale.
        let args = [
            "-nostats",
            "-hide_banner",
            "-i", testURL.path,
            "-i", referenceURL.path,
            "-lavfi", "[1:v][0:v]scale2ref=flags=bicubic[refscaled][dist];[dist][refscaled]libvmaf",
            "-f", "null", "-",
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args

        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw QualityMeasureError.ffmpegFailed("\(error)")
        }

        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let log = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw QualityMeasureError.ffmpegFailed("exit=\(process.terminationStatus). stderr: \(log.suffix(800))")
        }

        // libvmaf emits "VMAF score: 92.4321" on stderr.
        if let score = Self.parseVMAFScore(from: log) {
            return score
        }
        throw QualityMeasureError.vmafParseFailed(String(log.suffix(400)))
    }

    /// Parse "VMAF score: <number>" from a libvmaf stderr log. Returns
    /// nil if the marker isn't present. Internal for testability.
    static func parseVMAFScore(from log: String) -> Double? {
        // libvmaf log emits either "VMAF score: 92.43" or
        // "VMAF score = 92.43"; accept both.
        let lines = log.split(separator: "\n")
        for line in lines {
            let text = String(line)
            guard let range = text.range(of: "VMAF score") else { continue }
            let tail = text[range.upperBound...]
            // Skip past optional ':' / '=' / spaces.
            let scanner = Scanner(string: String(tail))
            scanner.charactersToBeSkipped = CharacterSet(charactersIn: " :=\t")
            if let score = scanner.scanDouble() {
                return score
            }
        }
        return nil
    }

    // MARK: - LPIPS (stub)

    /// LPIPS stub. A real LPIPS computation needs a deep network (AlexNet
    /// or VGG) run on every frame pair; that's a Phase B deliverable.
    /// For now this returns 0.0 so the field decodes cleanly and the
    /// harness can stamp the failure-reason for the run when needed.
    ///
    /// TODO(Phase B): wire a real LPIPS via MLX or CoreML.
    public func lpips(reference: CVPixelBuffer, test: CVPixelBuffer) -> Double {
        _ = reference  // silence unused-warning
        _ = test
        return 0.0
    }

    // MARK: - Helpers

    /// Mean squared error on the [0, 255] domain across the luma plane.
    func meanSquaredError(reference: CVPixelBuffer, test: CVPixelBuffer) throws -> Double {
        try ensureSameDimensions(reference, test)
        let (refPixels, testPixels) = try lumaPixels(reference: reference, test: test)
        guard !refPixels.isEmpty else { return 0.0 }

        var sumSq = 0.0
        for i in 0..<refPixels.count {
            let d = Double(refPixels[i]) - Double(testPixels[i])
            sumSq += d * d
        }
        return sumSq / Double(refPixels.count)
    }

    /// Confirm both buffers have matching width × height.
    private func ensureSameDimensions(_ a: CVPixelBuffer, _ b: CVPixelBuffer) throws {
        let aSize = CGSize(width: CVPixelBufferGetWidth(a), height: CVPixelBufferGetHeight(a))
        let bSize = CGSize(width: CVPixelBufferGetWidth(b), height: CVPixelBufferGetHeight(b))
        guard aSize == bSize else {
            throw QualityMeasureError.dimensionMismatch(refSize: aSize, testSize: bSize)
        }
    }

    /// Read the luma plane (channel 0 for planar YUV; channel 0 of a
    /// packed buffer otherwise) into a flat UInt8 array. Strips
    /// row-padding so the returned arrays are aligned 1:1.
    private func lumaPixels(reference: CVPixelBuffer, test: CVPixelBuffer) throws -> ([UInt8], [UInt8]) {
        let ref = try readLumaPlane(reference)
        let tst = try readLumaPlane(test)
        return (ref, tst)
    }

    private func readLumaPlane(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw QualityMeasureError.pixelBufferLockFailed
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let isPlanar = CVPixelBufferIsPlanar(buffer)

        let base: UnsafeMutableRawPointer?
        let bytesPerRow: Int
        if isPlanar {
            base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        } else {
            base = CVPixelBufferGetBaseAddress(buffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        }
        guard let raw = base else {
            throw QualityMeasureError.pixelBufferLockFailed
        }

        var result = [UInt8]()
        result.reserveCapacity(width * height)
        let ptr = raw.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for col in 0..<width {
                result.append(ptr[row * bytesPerRow + col])
            }
        }
        return result
    }
}
