//
// CorpusLoader.swift
// ForgeOptimizer / Benchmark
//
// Loads `Forge/Tests/Corpus/manifest.json` into a `Corpus` value.
//
// The manifest carries extra fields the schema doesn't define
// (`source_url`, `license`, `attribution`, `fetch_notes`); Swift's
// Decodable ignores unknown JSON keys, which matches the schema's
// "open nested structures" convention.
//
// Pre-fetch state caveat: `fetch_corpus.sh` populates `sha256`,
// `frame_rate`, `duration_s`, and `codec` lazily after clips are
// downloaded. Before that, the manifest carries `null` for those
// fields. The schema marks `duration_s` and `sha256` as required for
// a *report* — but the corpus *manifest* is the pre-fetch contract,
// not the report. The loader fills missing required fields with
// schema-conformant defaults (duration `0`, sha256 empty) so the
// loader still produces 30 clips before fetch has run.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import Foundation

public enum CorpusLoaderError: Error, Sendable, CustomStringConvertible {
    case fileNotFound(URL)
    case invalidJSON(String)
    case missingClips

    public var description: String {
        switch self {
        case .fileNotFound(let url): return "Corpus manifest not found at \(url.path)"
        case .invalidJSON(let detail): return "Corpus manifest malformed: \(detail)"
        case .missingClips: return "Corpus manifest has no clips"
        }
    }
}

/// Reads `manifest.json` into a `Corpus`.
///
/// Stateless — the actor is overkill here, but a struct keeps the
/// dependency arrow simple (`BenchmarkSuite` holds the loaded `Corpus`,
/// not a reference to the loader).
public struct CorpusLoader: Sendable {

    public init() {}

    /// Decode `manifest.json` at the given URL.
    public func load(from manifestURL: URL) throws -> Corpus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw CorpusLoaderError.fileNotFound(manifestURL)
        }

        let data = try Data(contentsOf: manifestURL)
        return try decode(data: data)
    }

    /// Decode a corpus from raw JSON data. Internal — `load(from:)` is
    /// the file-system entry point; this overload lets tests round-trip
    /// inline JSON without touching disk.
    func decode(data: Data) throws -> Corpus {
        // The manifest may have `null` for required schema fields
        // (`duration_s`, `sha256`) when run pre-fetch. Pre-process the
        // JSON to substitute schema-conformant defaults so the strict
        // `Decodable` types still bind.
        let normalized: Data
        do {
            normalized = try normalizeNulls(in: data)
        } catch {
            throw CorpusLoaderError.invalidJSON("\(error)")
        }

        let decoder = JSONDecoder()
        do {
            let corpus = try decoder.decode(Corpus.self, from: normalized)
            guard !corpus.clips.isEmpty else {
                throw CorpusLoaderError.missingClips
            }
            return corpus
        } catch let err as CorpusLoaderError {
            throw err
        } catch {
            throw CorpusLoaderError.invalidJSON("\(error)")
        }
    }

    /// Substitute `null` values for `duration_s` and `sha256` with
    /// `0` and `""` so the strict Codable types still bind. Other
    /// nullable fields (`frame_rate`, `codec`, `subcategory`) are
    /// already Optional in CorpusClip and need no normalization.
    private func normalizeNulls(in data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        guard var clips = root["clips"] as? [[String: Any]] else {
            return data
        }
        for i in clips.indices {
            var clip = clips[i]
            if clip["duration_s"] is NSNull || clip["duration_s"] == nil {
                clip["duration_s"] = 0.0
            }
            if clip["sha256"] is NSNull || clip["sha256"] == nil {
                clip["sha256"] = ""
            }
            clips[i] = clip
        }
        root["clips"] = clips
        return try JSONSerialization.data(withJSONObject: root, options: [])
    }
}
