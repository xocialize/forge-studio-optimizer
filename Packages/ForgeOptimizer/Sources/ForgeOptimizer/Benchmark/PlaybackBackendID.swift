//
// PlaybackBackendID.swift
// ForgeOptimizer / Benchmark
//
// Identifier for the four playback backends the Phase C.4 A/B compares
// (per ADR-0006). Maps 1:1 onto `PlaybackUpscaler.Backend` cases; the
// wire-format names are the same strings each tier reports via
// `PlaybackTier.name` (minus the `-x4` scale suffix) so JSON, CLI args,
// and tier identity stay in lockstep.
//
// Lives next to `BenchmarkRunner` rather than inside it so the type is
// available to:
//   - `BenchmarkSuite.runPlaybackBackendPass(backend:scale:clipID:)`
//   - `forge-benchmark-runner --playback-backend <name>` (CLI parser)
//   - tests that don't want to import the whole `BenchmarkRunner` namespace
//
// Plan ref: Docs/Forge-CodingPlan-v1.0.md §C.4
// ADR:      Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md §"Ship criterion"
//

import ForgeUpscaler
import Foundation

extension BenchmarkRunner {

    /// Identifier for the four playback backends in the C.4 A/B set.
    ///
    /// Wire-format strings match the `--playback-backend` CLI arg and
    /// (minus the `-x<scale>` suffix) the `PlaybackTier.name` value each
    /// tier reports. Round-trip Codable so the same identifier can be
    /// stored in a JSON report or parsed off the CLI.
    public enum PlaybackBackendID: String, Codable, Sendable, CaseIterable {

        /// EfRLFN MLX-Swift (~504K params, MIT). Maps to
        /// `PlaybackUpscaler.Backend.efrlfn`. Supports scale ∈ {2, 4}.
        case efrlfn = "efrlfn"

        /// SRVGGNetCompact `realesr-general-x4v3` (BSD-3-Clause). Maps to
        /// `PlaybackUpscaler.Backend.srvggnetGeneral`. x4 only.
        case srvggnetGeneral = "srvggnet-general"

        /// SRVGGNetCompact `realesr-general-wdn-x4v3` (BSD-3-Clause).
        /// Same architecture as `.srvggnetGeneral`, weight-denoised
        /// training. Maps to `PlaybackUpscaler.Backend.srvggnetGeneralWDN`.
        /// x4 only.
        case srvggnetGeneralWDN = "srvggnet-general-wdn"

        /// SRVGGNetCompact `realesr-animevideov3` (BSD-3-Clause). Maps to
        /// `PlaybackUpscaler.Backend.srvggnetAnime`. x4 only; the A/B
        /// against EfRLFN is asymmetric — EfRLFN has no anime-specific
        /// variant.
        case srvggnetAnime = "srvggnet-anime"

        /// Map this identifier onto the `PlaybackUpscaler.Backend` case
        /// the upscaler factory consumes. Total — every variant has a
        /// 1:1 mapping at the API surface.
        public func toPlaybackBackend(scale: Int) -> PlaybackUpscaler.Backend {
            switch self {
            case .efrlfn:              return .efrlfn(scale: scale)
            case .srvggnetGeneral:     return .srvggnetGeneral(scale: scale)
            case .srvggnetGeneralWDN:  return .srvggnetGeneralWDN(scale: scale)
            case .srvggnetAnime:       return .srvggnetAnime(scale: scale)
            }
        }

        /// True when the variant's weights ship at the requested scale.
        /// Today only EfRLFN has x2 weights vendored; SRVGGNetCompact
        /// ships x4-only.
        ///
        /// Phase C.5b TODO: wire EfRLFN x2 once the inference path
        /// validates parity at scale 2 (the safetensors are already
        /// vendored; the wrapper is x4-only out of caution).
        public func supportsScale(_ scale: Int) -> Bool {
            switch self {
            case .efrlfn:
                // efrlfn_x2.safetensors is vendored but the Phase C.5a
                // `EfRLFN_Playback` wrapper currently rejects scale != 4.
                // We treat scale 2 as legal at the identifier level here
                // so the CLI can route it through the `EfRLFN_Playback`
                // init, which will throw `PlaybackTierError.unsupportedScale`
                // until C.5b enables it. The CLI catches that and reports
                // it as a clean `.failed` row, same shape as a true
                // scale-mismatch.
                return scale == 2 || scale == 4
            case .srvggnetGeneral, .srvggnetGeneralWDN, .srvggnetAnime:
                return scale == 4
            }
        }

        /// Parse a `--playback-backend` argument value (one of the four
        /// wire-format names, a comma-separated list, or the literal
        /// `"all"` to expand to every `CaseIterable` variant).
        ///
        /// Lives on the library so the CLI parser and tests share a single
        /// implementation. Throws `PlaybackBackendID.ParseError` on an
        /// unknown name or an empty value.
        public static func parseList(_ raw: String) throws -> [PlaybackBackendID] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "all" {
                return PlaybackBackendID.allCases
            }
            var out: [PlaybackBackendID] = []
            for token in trimmed.split(separator: ",") {
                let s = token.trimmingCharacters(in: .whitespaces)
                guard let id = PlaybackBackendID(rawValue: s) else {
                    throw ParseError.unknownName(s)
                }
                out.append(id)
            }
            if out.isEmpty { throw ParseError.empty }
            return out
        }

        /// Errors thrown by `PlaybackBackendID.parseList`.
        public enum ParseError: Error, Sendable, CustomStringConvertible, Equatable {
            case unknownName(String)
            case empty

            public var description: String {
                switch self {
                case .unknownName(let s):
                    let valid = PlaybackBackendID.allCases
                        .map { $0.rawValue }.joined(separator: ", ")
                    return "unknown playback-backend '\(s)' (valid: \(valid), or 'all')"
                case .empty:
                    return "playback-backend value cannot be empty"
                }
            }
        }
    }
}
