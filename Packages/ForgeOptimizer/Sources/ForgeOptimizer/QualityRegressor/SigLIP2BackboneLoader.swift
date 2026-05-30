//
//  SigLIP2BackboneLoader.swift
//  ForgeOptimizer / QualityRegressor
//
//  Role: Actor-isolated lazy-download manager for the SigLIP2 vision backbone.
//        On first use, fetches `model.safetensors` + `config.json` from
//        `mlx-community/siglip2-base-patch16-224-8bit` at a pinned revision,
//        verifies the SHA256 of each file against an in-binary manifest, and
//        caches under `~/Library/Application Support/Forge/Models/SigLIP2/`.
//
//  Plan ref: Forge-CodingPlan-v1.0.md §E.2 / Task #27 (Phase E.2)
//  ADR:      Docs/ADRs/0005-siglip2-lazy-download.md (decision: lazy-download,
//            not bundled — backbone is ~400 MB, far above the §4 bundle-size
//            ceiling)
//
//  Upstream:
//    Repo:        https://huggingface.co/mlx-community/siglip2-base-patch16-224-8bit
//    Revision:    5249fc157310584fe99dae6964707278eb6df50f (pinned at Phase E.2 fetch)
//    Base model:  google/siglip2-base-patch16-224 (Apache-2.0)
//    Quantization: MLX int8 (group_size=64, bits=8)
//
//  Conventions:
//    - Pinned manifest (SHA256 of model.safetensors / config.json) hard-coded
//      below. Verified at first download; mismatch throws .checksumMismatch.
//    - Atomic writes: download → .tmp file, verify, then FileManager.moveItem.
//    - Progress callback fires on each chunk during the streaming download.
//    - macOS 15+ deployment per Package.swift (uses URL.applicationSupportDirectory,
//      requires macOS 13+; we deploy macOS 15+).
//
//  This file ships only the loader scaffolding. The MLX-Swift architecture port
//  (SigLIP2.swift) and the NR-IQA head (SigLIP2_IQA.swift) consume the loader's
//  output. Wiring into ModelRegistry + BenchmarkSuite.QualityMeasure is Phase E.5.
//

import Foundation
import CryptoKit
import MLX

/// Actor that owns the SigLIP2 backbone weight cache. Single-writer by actor
/// isolation; the cache root is shared with all concurrent readers.
///
/// Public surface:
///   - `ensureWeights(progress:)` — idempotent; downloads + verifies if missing.
///   - `loadIntoMLX()` — calls `ensureWeights` then `MLX.loadArrays` on the safetensors.
public actor SigLIP2BackboneLoader {

    // MARK: - Errors

    public enum LoaderError: Error, Sendable, CustomStringConvertible {
        case downloadFailed(URL, Error)
        case checksumMismatch(expected: String, actual: String, file: String)
        case cacheUnavailable(reason: String)
        case extractFailed(String)

        public var description: String {
            switch self {
            case .downloadFailed(let url, let err):
                return "SigLIP2 download failed for \(url.absoluteString): \(err)"
            case .checksumMismatch(let expected, let actual, let file):
                return "SigLIP2 checksum mismatch for \(file): expected \(expected), got \(actual)"
            case .cacheUnavailable(let reason):
                return "SigLIP2 cache unavailable: \(reason)"
            case .extractFailed(let detail):
                return "SigLIP2 file processing failed: \(detail)"
            }
        }
    }

    // MARK: - Types

    public struct DownloadProgress: Sendable {
        public let bytesDownloaded: Int64
        public let bytesTotal: Int64
        public let currentFile: String

        public init(bytesDownloaded: Int64, bytesTotal: Int64, currentFile: String) {
            self.bytesDownloaded = bytesDownloaded
            self.bytesTotal = bytesTotal
            self.currentFile = currentFile
        }
    }

    /// One file in the manifest. `filename` is the on-disk name in the cache
    /// directory (same as the upstream filename). `sha256` is the hex-encoded
    /// SHA256 of the file contents.
    public struct ManifestEntry: Sendable {
        public let filename: String
        public let sha256: String
        public let url: URL
        /// Expected size in bytes. Used to give a total to the progress callback
        /// before the HTTP response Content-Length arrives. Optional because the
        /// download still works without it.
        public let expectedSize: Int64?

        public init(filename: String, sha256: String, url: URL, expectedSize: Int64? = nil) {
            self.filename = filename
            self.sha256 = sha256
            self.url = url
            self.expectedSize = expectedSize
        }
    }

    // MARK: - Pinned manifest

    /// Pinned at Phase E.2 (Task #27). Both SHA256s + sizes verified against
    /// HuggingFace `x-linked-etag` and `x-linked-size` response headers on
    /// 2026-05-28 from the `mlx-community/siglip2-base-patch16-224-8bit`
    /// revision `5249fc157310584fe99dae6964707278eb6df50f`.
    ///
    /// Tokenizer is intentionally excluded — image-only NR-IQA doesn't tokenize
    /// text. Adding it here is harmless if a future task wants the text encoder.
    private static let pinnedRevision: String = "5249fc157310584fe99dae6964707278eb6df50f"

    /// The manifest of files to download. Order matters — first file's progress
    /// fires before the second's.
    public static let manifest: [ManifestEntry] = [
        ManifestEntry(
            filename: "config.json",
            sha256: "b551f88347bd722299bd0d66fccf11a85a366adc58f0c09180765e3d38508e19",
            url: URL(string: "https://huggingface.co/mlx-community/siglip2-base-patch16-224-8bit/resolve/\(pinnedRevision)/config.json")!,
            expectedSize: 351
        ),
        ManifestEntry(
            filename: "model.safetensors",
            sha256: "c2498ff9d590362c8c14becbcfa40fd172b105a8f4520c2e2a96905955651984",
            url: URL(string: "https://huggingface.co/mlx-community/siglip2-base-patch16-224-8bit/resolve/\(pinnedRevision)/model.safetensors")!,
            expectedSize: 399_521_079
        ),
    ]

    // MARK: - State

    public let cacheRoot: URL
    private let urlSession: URLSession

    // MARK: - Init

    public init(
        cacheRoot: URL = SigLIP2BackboneLoader.defaultCacheRoot,
        urlSession: URLSession = .shared
    ) {
        self.cacheRoot = cacheRoot
        self.urlSession = urlSession
    }

    /// `~/Library/Application Support/Forge/Models/SigLIP2/`.
    ///
    /// Uses `URL.applicationSupportDirectory` (macOS 13+). Per Package.swift the
    /// minimum deployment is macOS 14 so this is always available; production
    /// distribution is macOS 15+ per the platform line in `Forge-PRD-v0.3.md`.
    public static var defaultCacheRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "Forge", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: "SigLIP2", directoryHint: .isDirectory)
    }

    // MARK: - Public API

    /// Ensure the cached weights are present + verified.
    /// - Parameter progress: Optional progress callback fired per chunk during
    ///   download. NOT called for already-cached files (instantly verified).
    /// - Returns: The cache root URL (== `self.cacheRoot`) once all files in
    ///   the manifest are present and SHA256-verified.
    @discardableResult
    public func ensureWeights(
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        try createCacheDirectoryIfNeeded()

        for entry in Self.manifest {
            let destination = cacheRoot.appending(path: entry.filename)

            // Skip if already cached AND verified.
            if FileManager.default.fileExists(atPath: destination.path) {
                let cachedSha = try Self.sha256Hex(of: destination)
                if cachedSha == entry.sha256 {
                    continue
                }
                // Cached file is corrupt or stale — delete it and re-download.
                try? FileManager.default.removeItem(at: destination)
            }

            try await downloadAndVerify(entry: entry, destination: destination, progress: progress)
        }

        return cacheRoot
    }

    /// Load the verified weights into MLX as a flat `[String: MLXArray]` dict.
    /// Calls `ensureWeights()` first (idempotent), then `MLX.loadArrays` on the
    /// safetensors.
    ///
    /// The returned dict is the raw safetensors content — for the 8-bit MLX
    /// quantized variant this includes the per-tensor `scales` / `biases` keys
    /// alongside the dequantized weight stems. Phase E.5 integration will
    /// either dequantize on load (CPU/GPU memory hit) or load into a quantized
    /// MLX module (faster, smaller). For Phase E.2 architecture verification,
    /// `SigLIP2VisionModel.loadWeights(from:)` is what wires the raw arrays
    /// into the module hierarchy.
    public func loadIntoMLX() async throws -> [String: MLXArray] {
        _ = try await ensureWeights()
        let safetensorsURL = cacheRoot.appending(path: "model.safetensors")

        do {
            let arrays = try MLX.loadArrays(url: safetensorsURL)
            // Materialize lazy tensors so unevaluated arrays don't serialize as zeros
            // when re-saved (per mlx-porting skill pitfall — MLX is lazy).
            for (_, value) in arrays {
                MLX.eval(value)
            }
            return arrays
        } catch {
            throw LoaderError.extractFailed("MLX.loadArrays failed for \(safetensorsURL.path): \(error)")
        }
    }

    // MARK: - Implementation

    private func createCacheDirectoryIfNeeded() throws {
        do {
            try FileManager.default.createDirectory(
                at: cacheRoot,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw LoaderError.cacheUnavailable(reason: "createDirectory(\(cacheRoot.path)): \(error)")
        }
    }

    /// Stream-download `entry.url` to `destination.tmp`, verify SHA256, then
    /// `FileManager.moveItem` to `destination`. Progress callback fires on
    /// every chunk read.
    private func downloadAndVerify(
        entry: ManifestEntry,
        destination: URL,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws {
        let tempURL = destination.appendingPathExtension("tmp")
        // Clean any leftover temp from a prior aborted download.
        try? FileManager.default.removeItem(at: tempURL)

        // Open a streaming bytes session. `URLSession.bytes(for:)` gives us an
        // AsyncSequence of bytes with the HTTPURLResponse alongside.
        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await urlSession.bytes(for: URLRequest(url: entry.url))
        } catch {
            throw LoaderError.downloadFailed(entry.url, error)
        }

        // Reject non-2xx responses early — HuggingFace returns 200 even on the
        // redirected CDN URL because URLSession.bytes follows redirects by
        // default.
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw LoaderError.downloadFailed(
                entry.url,
                NSError(domain: "SigLIP2BackboneLoader", code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            )
        }

        let totalBytes: Int64 = response.expectedContentLength > 0
            ? response.expectedContentLength
            : (entry.expectedSize ?? -1)

        // Create empty file + open for writing.
        FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: nil)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: tempURL)
        } catch {
            throw LoaderError.downloadFailed(entry.url, error)
        }
        defer {
            try? handle.close()
        }

        // Stream + hash incrementally to avoid loading 400 MB into memory.
        var hasher = SHA256()
        var bytesWritten: Int64 = 0
        var chunk: [UInt8] = []
        chunk.reserveCapacity(64 * 1024)

        do {
            for try await byte in asyncBytes {
                chunk.append(byte)
                if chunk.count >= 64 * 1024 {
                    let data = Data(chunk)
                    try handle.write(contentsOf: data)
                    hasher.update(data: data)
                    bytesWritten += Int64(chunk.count)
                    chunk.removeAll(keepingCapacity: true)
                    progress?(DownloadProgress(
                        bytesDownloaded: bytesWritten,
                        bytesTotal: totalBytes,
                        currentFile: entry.filename
                    ))
                }
            }
            if !chunk.isEmpty {
                let data = Data(chunk)
                try handle.write(contentsOf: data)
                hasher.update(data: data)
                bytesWritten += Int64(chunk.count)
                progress?(DownloadProgress(
                    bytesDownloaded: bytesWritten,
                    bytesTotal: totalBytes,
                    currentFile: entry.filename
                ))
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw LoaderError.downloadFailed(entry.url, error)
        }

        // Verify SHA256.
        let digest = hasher.finalize()
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        guard actualHex == entry.sha256 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw LoaderError.checksumMismatch(
                expected: entry.sha256,
                actual: actualHex,
                file: entry.filename
            )
        }

        // Atomic move into place.
        do {
            // Remove an existing file (e.g. left over from a crashed earlier run)
            // before move — FileManager.moveItem fails if destination exists.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw LoaderError.extractFailed("moveItem(\(tempURL.path) -> \(destination.path)): \(error)")
        }
    }

    // MARK: - SHA helpers

    /// Hex-encoded SHA256 of the file at `url`. Reads the file in 1 MiB chunks
    /// to keep memory bounded for the ~400 MB safetensors.
    static func sha256Hex(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LoaderError.cacheUnavailable(reason: "open(\(url.path)): \(error)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
