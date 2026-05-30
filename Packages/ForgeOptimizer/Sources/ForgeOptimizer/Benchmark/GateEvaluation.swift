//
// GateEvaluation.swift
// ForgeOptimizer / Benchmark
//
// `gates` payload of a benchmark report. `GateResult` is the on-disk
// shape (per schema §4); `GateEvaluator.swift` produces these by
// applying the catalog in schema §5 to a report.
//
// `hardware_required` is honored by skipping the gate when
// `report.hardware.chip` doesn't match — see ADR 0001 §Decision 4 for
// the rationale (M5 Max-only hardware locally, M4 Pro / M5 Pro gates
// reported but unevaluated).
//
// Per Forge 2026 Q2 refresh plan §A.2 / schema §5–§6.
//

import Foundation

public struct GateEvaluation: Codable, Sendable {
    public let version: String
    public let allPassed: Bool?
    public let results: [GateResult]

    public init(version: String, allPassed: Bool? = nil, results: [GateResult]) {
        self.version = version
        self.allPassed = allPassed
        self.results = results
    }

    enum CodingKeys: String, CodingKey {
        case version
        case allPassed = "all_passed"
        case results
    }
}

public struct GateResult: Codable, Sendable {
    public let gateID: String
    public let description: String
    public let comparison: Comparison
    public let target: Double
    public let actual: Double
    public let passed: Bool
    public let hardwareRequired: String?
    public let corpusSubset: CorpusSubset?
    public let tolerance: Double?

    public enum Comparison: String, Codable, Sendable {
        case lte, gte, eq, lt, gt
    }

    public enum CorpusSubset: String, Codable, Sendable {
        case general, signage, legacy, all
    }

    public init(
        gateID: String,
        description: String,
        comparison: Comparison,
        target: Double,
        actual: Double,
        passed: Bool,
        hardwareRequired: String? = nil,
        corpusSubset: CorpusSubset? = nil,
        tolerance: Double? = nil
    ) {
        self.gateID = gateID
        self.description = description
        self.comparison = comparison
        self.target = target
        self.actual = actual
        self.passed = passed
        self.hardwareRequired = hardwareRequired
        self.corpusSubset = corpusSubset
        self.tolerance = tolerance
    }

    enum CodingKeys: String, CodingKey {
        case gateID = "gate_id"
        case description, comparison, target, actual, passed
        case hardwareRequired = "hardware_required"
        case corpusSubset = "corpus_subset"
        case tolerance
    }
}
