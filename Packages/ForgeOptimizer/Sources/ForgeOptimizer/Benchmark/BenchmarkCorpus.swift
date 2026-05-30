//
// BenchmarkCorpus.swift
// ForgeOptimizer / Benchmark
//
// Corpus + CorpusClip Codable types from the benchmark schema (§4).
//
// `CorpusClip` matches the schema's required-field set exactly. Extra
// fields present in `Forge/Tests/Corpus/manifest.json` (`source_url`,
// `license`, `attribution`, `fetch_notes`) are intentionally NOT
// declared here — Swift's `Decodable` ignores unknown JSON keys, which
// matches the schema's "open nested structures" convention from §1.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import Foundation

public struct Corpus: Codable, Sendable {
    public let name: String
    public let version: String
    public let clips: [CorpusClip]

    public init(name: String, version: String, clips: [CorpusClip]) {
        self.name = name
        self.version = version
        self.clips = clips
    }
}

public struct CorpusClip: Codable, Sendable {
    public let id: String
    public let category: Category
    public let subcategory: String?
    public let resolution: String
    public let frameRate: Double?
    public let durationS: Double
    public let codec: String?
    public let sha256: String

    public enum Category: String, Codable, Sendable {
        case general, signage, legacy
    }

    public init(
        id: String,
        category: Category,
        subcategory: String? = nil,
        resolution: String,
        frameRate: Double? = nil,
        durationS: Double,
        codec: String? = nil,
        sha256: String
    ) {
        self.id = id
        self.category = category
        self.subcategory = subcategory
        self.resolution = resolution
        self.frameRate = frameRate
        self.durationS = durationS
        self.codec = codec
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case id, category, subcategory, resolution
        case frameRate = "frame_rate"
        case durationS = "duration_s"
        case codec, sha256
    }
}
