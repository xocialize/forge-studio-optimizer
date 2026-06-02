import CoreVideo
import Foundation

/// Full-reference perceptual scorer backed by the **SSIMULACRA2 reference binary**
/// (libjxl / Jon Sneyers). This is the still analog of how the video quality-target uses
/// libvmaf: an external, accurate metric injected at the `StillQualityScoring` seam at
/// **encode time**, never linked into the core encode path (ADR-0021). It's the right
/// LOSSY floor — SigLIP2 NR-IQA is the on-device restoration *gate*, but it's nearly flat
/// across the compression knob (Phase-4 finding), whereas SSIMULACRA2 is a true
/// fidelity-vs-reference gradient.
///
/// Score range −∞…100, monotonic with quality (per the reference tool):
///   90 = very high (indistinguishable at 1:1) · 70 = high · 50 = medium · 30 = low.
/// Requires the binary: `brew install jpeg-xl` (provides `ssimulacra2`). Because it
/// shells out to the reference implementation, the scores ARE the reference — there is no
/// numerical port to validate (and nothing metric-specific is linked into ImageBridge).
public struct BinarySSIMULACRA2Scorer: StillQualityScoring, @unchecked Sendable {

    public enum ScorerError: Error, CustomStringConvertible {
        case binaryNotFound
        case runFailed(String)
        public var description: String {
            switch self {
            case .binaryNotFound: return "ssimulacra2 binary not found (brew install jpeg-xl)"
            case .runFailed(let s): return "ssimulacra2 failed: \(s)"
            }
        }
    }

    /// Recommended encode floor for signage lossy targets. 90 ≈ visually lossless at 1:1;
    /// the search ships the smallest encode still scoring ≥ this. Tune per appetite
    /// (85 = a touch more compression, still high quality).
    public static let recommendedFloor: Double = 90.0

    private let binaryPath: String
    private let encoder = ImageIOEncoderImpl()

    public init(binaryPath: String? = nil) throws {
        if let p = binaryPath, FileManager.default.isExecutableFile(atPath: p) {
            self.binaryPath = p; return
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = ["/opt/homebrew/bin/ssimulacra2", "/usr/local/bin/ssimulacra2"]
            + pathDirs.map { "\($0)/ssimulacra2" }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ScorerError.binaryNotFound
        }
        self.binaryPath = found
    }

    /// Whether the binary resolves — lets a runner fall back gracefully.
    public static func isAvailable(at path: String? = nil) -> Bool {
        (try? BinarySSIMULACRA2Scorer(binaryPath: path)) != nil
    }

    /// Full-reference: `reference` is the pristine/restored buffer, `distorted` the
    /// candidate. On any failure returns 0 (a hard floor-miss) so the search stays safe;
    /// use `scoreThrowing` to surface errors.
    public func score(reference: CVPixelBuffer, distorted: CVPixelBuffer) -> Double {
        (try? scoreThrowing(reference: reference, distorted: distorted)) ?? 0
    }

    public func scoreThrowing(reference: CVPixelBuffer, distorted: CVPixelBuffer) throws -> Double {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = dir.appendingPathComponent("ref.png")
        let dist = dir.appendingPathComponent("dist.png")
        // Lossless PNGs preserve the exact pixels the binary scores (no oxipng needed).
        let png = StillEncoderSettings(format: .png, stripMetadata: true, losslessOptimize: false)
        try encoder.encode(reference, settings: png, metadata: nil, to: ref)
        try encoder.encode(distorted, settings: png, metadata: nil, to: dist)

        let proc = Process()
        proc.executableURL = URL(filePath: binaryPath)
        proc.arguments = [ref.path, dist.path]
        let outPipe = Pipe(); proc.standardOutput = outPipe; proc.standardError = Pipe()
        try proc.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0,
              let last = text.split(whereSeparator: \.isNewline).last,
              let value = Double(last.trimmingCharacters(in: .whitespaces)) else {
            throw ScorerError.runFailed("status \(proc.terminationStatus): '\(text)'")
        }
        return value
    }
}
