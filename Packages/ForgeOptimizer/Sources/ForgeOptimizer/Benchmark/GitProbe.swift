//
// GitProbe.swift
// ForgeOptimizer / Benchmark
//
// Captures the `GitInfo` block of a benchmark report by shelling out to
// `git`. Tolerates non-git directories (returns nil) — `BenchmarkSuite`
// supplies a placeholder GitInfo if probing fails.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import Foundation

public struct GitProbe: Sendable {

    public let workingDirectory: URL

    /// Defaults to the current working directory.
    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    /// Capture git provenance, or nil if the working directory isn't a git
    /// repo (or `git` isn't on PATH).
    public func snapshot() -> GitInfo? {
        guard let sha = run(["rev-parse", "HEAD"]),
              !sha.isEmpty else {
            return nil
        }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"]) ?? ""
        let dirty = !(run(["status", "--porcelain"]) ?? "").isEmpty
        let remoteStr = run(["config", "--get", "remote.origin.url"]) ?? ""
        let remoteURL = remoteStr.isEmpty ? nil : URL(string: remoteStr)

        return GitInfo(
            sha: sha,
            branch: branch,
            dirty: dirty,
            remoteURL: remoteURL
        )
    }

    /// Runs `git <args>` in the configured working directory. Returns
    /// trimmed stdout on success; nil on any failure (non-zero exit,
    /// missing binary, not a repo).
    private func run(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = workingDirectory

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

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
