//
// DependencyProbe.swift
// ForgeOptimizer / Benchmark
//
// Captures the `Dependencies` block of a benchmark report. The MLX
// version is pulled from `Package.resolved` (the only place that's
// reliably in sync after `swift package resolve`); Swift / Xcode /
// ffmpeg are queried via subprocess.
//
// `coreml_runtime` has no clean API to query and is left nil; the
// benchmark report's `coreml_runtime` field is optional in the schema.
//
// Per Forge 2026 Q2 refresh plan §A.2 + ADR 0002 (ffmpeg-full at the
// absolute path defeats subprocess PATH scrubbing).
//

import Foundation

public struct DependencyProbe: Sendable {

    /// Path to the package's resolved file. Required for the MLX
    /// version pin to round-trip into the report.
    public let packageResolvedURL: URL?

    /// Path to ffmpeg-full's CLI. Per ADR 0002 the absolute Homebrew
    /// path is intentional — never use the `ffmpeg` on `$PATH` because
    /// the runtime Homebrew formula was split into a minimal `ffmpeg`
    /// that lacks `drawtext` / libx264 / network. Returns nil if the
    /// binary is missing.
    public let ffmpegPath: String

    public init(
        packageResolvedURL: URL? = nil,
        ffmpegPath: String = "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
    ) {
        self.packageResolvedURL = packageResolvedURL
        self.ffmpegPath = ffmpegPath
    }

    /// Capture all probeable dependency versions. Best-effort: missing
    /// tools surface as nil in the optional fields. The `mlxVersion` /
    /// `mlxSwiftVersion` / `swiftVersion` fields are required by the
    /// schema, so the probe uses empty-string fallbacks for the
    /// MLX-version cases (the calling harness can override with a
    /// known-good value if needed).
    public func snapshot() -> Dependencies {
        let mlx = mlxVersion() ?? ""

        return Dependencies(
            mlxVersion: mlx,
            mlxSwiftVersion: mlx,  // shares the version per Phase A.1 finding
            swiftVersion: swiftVersion() ?? "",
            xcodeVersion: xcodeVersion(),
            ffmpegVersion: ffmpegVersion(),
            coremlRuntime: nil
        )
    }

    // MARK: - MLX

    /// Read `Package.resolved` JSON, return the `mlx-swift` pin's
    /// `state.version` string.
    func mlxVersion() -> String? {
        guard let url = packageResolvedURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // SPM v2 shape: {"pins": [{"identity": "...", "state": {"version": "..."}}, ...]}
        guard let root = raw as? [String: Any] else { return nil }
        guard let pins = root["pins"] as? [[String: Any]] else { return nil }

        for pin in pins {
            guard let identity = pin["identity"] as? String else { continue }
            if identity == "mlx-swift" {
                if let state = pin["state"] as? [String: Any],
                   let version = state["version"] as? String {
                    return version
                }
            }
        }
        return nil
    }

    // MARK: - Subprocess versions

    func swiftVersion() -> String? {
        guard let raw = Self.runCapturingOutput("/usr/bin/swift", args: ["--version"]) else {
            return nil
        }
        // First line, e.g. "swift-driver version: 1.115.1 Apple Swift version 6.0.3 ..."
        return raw.split(separator: "\n").first.map(String.init)
    }

    func xcodeVersion() -> String? {
        guard let raw = Self.runCapturingOutput("/usr/bin/xcodebuild", args: ["-version"]) else {
            return nil
        }
        return raw.split(separator: "\n").first.map(String.init)
    }

    func ffmpegVersion() -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: ffmpegPath) else { return nil }
        guard let raw = Self.runCapturingOutput(ffmpegPath, args: ["-version"]) else {
            return nil
        }
        return raw.split(separator: "\n").first.map(String.init)
    }

    // MARK: - Subprocess helper

    static func runCapturingOutput(_ executable: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        // swift --version may emit on stderr depending on driver; merge
        // by reading both.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        let combined = out.isEmpty ? err : out
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
