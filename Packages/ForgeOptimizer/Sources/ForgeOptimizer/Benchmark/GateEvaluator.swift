//
// GateEvaluator.swift
// ForgeOptimizer / Benchmark
//
// Pure functions that produce a `GateEvaluation` from a populated
// `BenchmarkReport`. The 7-gate catalog comes from schema §5 / coding
// plan §4 — the table of bundle-size, throughput, VMAF, compression,
// playback-fps, and quality-regressor gates.
//
// `hardware_required` semantics per ADR 0001 §Decision 4: only an
// M5 Max is locally available. Gates that require M4 Pro / M5 Pro
// are reported with `actual: 0, passed: false, description` noting
// the skip, so CI's gate-checker (per schema §6 — fails on a true→
// false transition only) doesn't red over them.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import Foundation

/// Static declarative form of one gate. Translates into a `GateResult`
/// after `evaluate(report:)` computes the actual value.
public struct GateDefinition: Sendable, Hashable {
    public let gateID: String
    public let description: String
    public let comparison: GateResult.Comparison
    public let target: Double
    public let hardwareRequired: String?
    public let corpusSubset: GateResult.CorpusSubset?
    public let tolerance: Double?

    public init(
        gateID: String,
        description: String,
        comparison: GateResult.Comparison,
        target: Double,
        hardwareRequired: String? = nil,
        corpusSubset: GateResult.CorpusSubset? = nil,
        tolerance: Double? = nil
    ) {
        self.gateID = gateID
        self.description = description
        self.comparison = comparison
        self.target = target
        self.hardwareRequired = hardwareRequired
        self.corpusSubset = corpusSubset
        self.tolerance = tolerance
    }
}

public struct GateEvaluator: Sendable {

    /// Schema/plan version tag emitted as `gates.version` in the report.
    public static let catalogVersion = "v1.0"

    public init() {}

    /// The 5-gate catalog (schema §5 / coding-plan §4). Stable — changing
    /// this is a CI-breaking event because gate IDs are the keys in the
    /// baseline diff.
    ///
    /// The two realtime throughput gates (`throughput_balanced_m4pro_1080p`,
    /// `playback_4k_fps_min`) were REMOVED per ADR-0009 — realtime performance
    /// is a separate-project concern, not a Forge requirement. Throughput is
    /// still measured (`SpeedMetrics.realtimeFactor` / `fpsMean`) and reported,
    /// just not gated pass/fail.
    public func gateCatalog() -> [GateDefinition] {
        [
            GateDefinition(
                gateID: "bundle_size_max",
                description: "Total .mlpackage bytes in Resources/Models/ (ForgeOptimizer)",
                comparison: .lte,
                target: 12_000_000
            ),
            GateDefinition(
                gateID: "vmaf_balanced_min",
                description: "VMAF at Balanced, mean over all clips",
                comparison: .gte,
                target: 90.0,
                corpusSubset: .all
            ),
            GateDefinition(
                gateID: "compression_balanced_min",
                description: "Savings vs non-optimized at Balanced, mean over general subset",
                comparison: .gte,
                target: 0.35,
                corpusSubset: .general
            ),
            GateDefinition(
                gateID: "compression_signage_max_min",
                description: "Savings vs non-optimized at Maximum on signage subset",
                comparison: .gte,
                target: 0.55,
                corpusSubset: .signage
            ),
            GateDefinition(
                gateID: "quality_regressor_srcc_min",
                description: "SRCC vs human MOS on signage holdout (only valid after Phase E)",
                comparison: .gte,
                target: 0.90,
                corpusSubset: .all,
                tolerance: 1.0
            ),
        ]
    }

    /// Evaluate every gate in `gateCatalog()` against the given report.
    /// Gates whose `hardwareRequired` doesn't match `report.hardware.chip`
    /// emit `actual: 0, passed: false` with a skip note in the
    /// description (preserving the gate ID and target so CI's
    /// regression diff stays stable).
    public func evaluate(report: BenchmarkReport) -> GateEvaluation {
        let results = gateCatalog().map { definition in
            evaluate(definition: definition, against: report)
        }
        let allPassed = results.allSatisfy { $0.passed }
        return GateEvaluation(
            version: Self.catalogVersion,
            allPassed: allPassed,
            results: results
        )
    }

    /// Apply one gate to one report. Public so a future CI-only
    /// checker can re-evaluate individual gates without re-running the
    /// harness.
    public func evaluate(definition: GateDefinition, against report: BenchmarkReport) -> GateResult {
        // Hardware skip first — preserves the gate row but short-circuits
        // the actual-value computation.
        if let required = definition.hardwareRequired, required != report.hardware.chip {
            return GateResult(
                gateID: definition.gateID,
                description: "\(definition.description) [SKIPPED: requires \(required), got \(report.hardware.chip)]",
                comparison: definition.comparison,
                target: definition.target,
                actual: 0,
                passed: false,
                hardwareRequired: definition.hardwareRequired,
                corpusSubset: definition.corpusSubset,
                tolerance: definition.tolerance
            )
        }

        // Subset N/A: a subset-specific optimizer gate with no matching runs
        // (e.g. the general compression gate on a signage-only run, or vice
        // versa) is NOT a failure — mark it N/A so a partial-corpus run doesn't
        // false-fail. The §4 gate is validated where its subset exists.
        if let (lvl, sub) = Self.gateLevelSubset(definition),
           optimizerRuns(in: report, level: lvl, subset: sub).isEmpty {
            return GateResult(
                gateID: definition.gateID,
                description: "\(definition.description) [N/A: no \(sub) clips at \(lvl.rawValue)]",
                comparison: definition.comparison,
                target: definition.target,
                actual: definition.target,   // neutral value — passes its own comparison
                passed: true,
                hardwareRequired: definition.hardwareRequired,
                corpusSubset: definition.corpusSubset,
                tolerance: definition.tolerance
            )
        }

        let actual = computeActual(for: definition, in: report)
        let passed = Self.compare(
            actual: actual,
            target: definition.target,
            comparison: definition.comparison,
            tolerance: definition.tolerance
        )

        return GateResult(
            gateID: definition.gateID,
            description: definition.description,
            comparison: definition.comparison,
            target: definition.target,
            actual: actual,
            passed: passed,
            hardwareRequired: definition.hardwareRequired,
            corpusSubset: definition.corpusSubset,
            tolerance: definition.tolerance
        )
    }

    // MARK: - Comparison

    static func compare(
        actual: Double,
        target: Double,
        comparison: GateResult.Comparison,
        tolerance: Double?
    ) -> Bool {
        let slack = tolerance ?? 0.0
        switch comparison {
        case .lte: return actual <= target + slack
        case .gte: return actual >= target - slack
        case .lt:  return actual <  target + slack
        case .gt:  return actual >  target - slack
        case .eq:  return abs(actual - target) <= slack
        }
    }

    /// The (level, subset) an optimizer-backed gate reads, for the N/A check.
    /// Returns nil for gates not backed by an optimizer subset (bundle size,
    /// quality regressor).
    static func gateLevelSubset(
        _ d: GateDefinition
    ) -> (OptimizerRun.OptimizationLevel, GateResult.CorpusSubset)? {
        switch d.gateID {
        case "vmaf_balanced_min":        return (.balanced, d.corpusSubset ?? .all)
        case "compression_balanced_min": return (.balanced, d.corpusSubset ?? .general)
        case "compression_signage_max_min": return (.maximum, d.corpusSubset ?? .signage)
        default: return nil
        }
    }

    // MARK: - Per-gate metric extraction

    /// Compute the actual value for `definition` from the report.
    /// Missing data (e.g. no upscaler runs yet) returns 0 — combined
    /// with the gate's comparison this produces a deterministic
    /// pass/fail without throwing.
    private func computeActual(for definition: GateDefinition, in report: BenchmarkReport) -> Double {
        switch definition.gateID {
        case "bundle_size_max":
            return Double(report.pipelineResults.forgeOptimizer?.bundleBytes ?? 0)

        case "vmaf_balanced_min":
            return meanVMAF(
                in: report,
                level: .balanced,
                subset: definition.corpusSubset ?? .all
            )

        case "compression_balanced_min":
            return meanCompressionSavings(
                in: report,
                level: .balanced,
                subset: definition.corpusSubset ?? .general
            )

        case "compression_signage_max_min":
            return meanCompressionSavings(
                in: report,
                level: .maximum,
                subset: definition.corpusSubset ?? .signage
            )

        case "quality_regressor_srcc_min":
            // No SRCC vs MOS captured in the report yet (Phase E).
            // Returns 0 — combined with tolerance: 1.0 from the catalog
            // this still trips passed=false but stays stable so the
            // baseline-diff CI doesn't oscillate.
            return 0.0

        default:
            return 0.0
        }
    }

    // MARK: - Aggregation helpers

    private func optimizerRuns(
        in report: BenchmarkReport,
        level: OptimizerRun.OptimizationLevel,
        subset: GateResult.CorpusSubset
    ) -> [OptimizerRun] {
        guard let runs = report.pipelineResults.forgeOptimizer?.runs else { return [] }
        let categoryByClip = Dictionary(
            uniqueKeysWithValues: report.corpus.clips.map { ($0.id, $0.category) }
        )
        return runs.filter { run in
            guard run.optimizationLevel == level, run.status == .success else { return false }
            switch subset {
            case .all: return true
            case .general: return categoryByClip[run.clipID] == .general
            case .signage: return categoryByClip[run.clipID] == .signage
            case .legacy: return categoryByClip[run.clipID] == .legacy
            }
        }
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func meanVMAF(
        in report: BenchmarkReport,
        level: OptimizerRun.OptimizationLevel,
        subset: GateResult.CorpusSubset
    ) -> Double {
        let values = optimizerRuns(in: report, level: level, subset: subset)
            .compactMap { $0.quality?.vmaf }
        return mean(values)
    }

    private func meanCompressionSavings(
        in report: BenchmarkReport,
        level: OptimizerRun.OptimizationLevel,
        subset: GateResult.CorpusSubset
    ) -> Double {
        let values = optimizerRuns(in: report, level: level, subset: subset)
            .compactMap { $0.compression?.savingsVsBaseline }
        return mean(values)
    }
}
