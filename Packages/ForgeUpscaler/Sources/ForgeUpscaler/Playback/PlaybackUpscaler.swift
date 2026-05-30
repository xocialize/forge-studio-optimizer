// PlaybackUpscaler.swift
//
// Role: Fast, quality-first upscaler (the "playback" tier). Delegates all
//       model work to a concrete `PlaybackTier`; this class is a thin
//       façade that records the active tier and forwards `upscale(_:)`.
//       Not realtime-gated — realtime SR is a separate-project concern (ADR-0009).
//
// Plan reference: Docs/Forge-CodingPlan-v1.0.md §C
// ADR:           Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md
// Phase status:  C.5a (this refactor) — backend selector lives here for
//                the Phase C.4 EfRLFN ↔ SRVGGNetCompact A/B; C.5b will
//                lock in the winning default.
//
// Behaviour notes:
// - Two construction paths:
//     * `init(backend:)` — explicit backend selection. Used by Phase C.4
//       benchmark code and any caller that wants to pin a specific tier.
//     * `init(scale:preset:)` — backward-compat shim. Routes `.anime` to
//       the SRVGGNetCompact anime variant and everything else to EfRLFN
//       (which Phase C.4 is expected to pick per ADR-0006). Documented
//       as a temporary shim until C.5b finalises the default.
// - The legacy `init(modelURL:scale:tileSize:tileOverlap:)` is no longer
//   wired — its CoreML mlpackages were never vendored. We keep the
//   signature alive only as `@available(*, unavailable)` to give callers
//   a clean compile error pointing at `Backend`.

import CoreVideo
import Foundation

/// Fast, quality-first upscaling. Backend-agnostic — wraps a `PlaybackTier`.
/// Not realtime-gated (ADR-0009); throughput is measured, not required. Defaults
/// to MLX-Swift **SRVGGNetCompact `realesr-general-x4v3`** (Task #28,
/// BSD-3-Clause) — the Phase C.4 A/B winner (see ADR-0008). EfRLFN remains
/// selectable via `init(backend:)` but is NOT the default: the C.4 gate
/// found it −26.8 VMAF behind SRVGGNet-general across the 30-clip corpus
/// and slightly slower, failing ADR-0006's ship criterion on all 30 clips.
public final class PlaybackUpscaler: @unchecked Sendable {

    /// Selectable playback backend.
    public enum Backend: Sendable {

        /// EfRLFN MLX-Swift (~504K params, MIT). Considered for the playback
        /// default in ADR-0006, but the Phase C.4 A/B (ADR-0008) rejected it:
        /// −26.8 VMAF vs SRVGGNet-general, 0/30 clips met the +1.0 ship
        /// criterion. Kept selectable for re-evaluation (e.g. a future
        /// degradation-aware A/B on its StreamSR home turf) but not default.
        case efrlfn(scale: Int)

        /// SRVGGNetCompact `realesr-general-x4v3` (BSD-3-Clause).
        case srvggnetGeneral(scale: Int)

        /// SRVGGNetCompact `realesr-general-wdn-x4v3` (BSD-3-Clause).
        /// Same architecture as `.srvggnetGeneral`, trained with weight
        /// denoising — different weight file, different perceptual
        /// trade-off.
        case srvggnetGeneralWDN(scale: Int)

        /// SRVGGNetCompact `realesr-animevideov3` (BSD-3-Clause).
        case srvggnetAnime(scale: Int)

        /// Default general-content backend. SRVGGNetCompact general x4 —
        /// the Phase C.4 A/B winner (ADR-0008), superseding ADR-0006's
        /// provisional EfRLFN default.
        public static var defaultGeneral: Backend { .srvggnetGeneral(scale: 4) }

        /// Default anime-content backend. SRVGGNetCompact anime x4 —
        /// anime-specific EfRLFN weights are not yet available.
        public static var defaultAnime: Backend { .srvggnetAnime(scale: 4) }
    }

    /// The active playback tier. Public so benchmarks can report
    /// `tier.name` and `tier.scaleFactor`.
    public let tier: PlaybackTier

    /// Upscale factor reported by the active tier. Preserved for source
    /// compatibility with the previous `PlaybackUpscaler.scale` field.
    public var scale: Int { tier.scaleFactor }

    // MARK: - Init

    /// Initialise from an explicit `PlaybackTier`. Tests and advanced
    /// callers inject a custom tier through this path.
    public init(tier: PlaybackTier) {
        self.tier = tier
    }

    /// Initialise from a `Backend` enum case. The Phase C.4 benchmark
    /// runner and any other caller that wants explicit backend control
    /// should use this.
    public init(backend: Backend) throws {
        self.tier = try Self.makeTier(for: backend)
    }

    /// Initialise from a content preset using bundled models — backward-
    /// compat shim for callers that don't know about `Backend`.
    ///
    /// Routing (post-C.4, ADR-0008):
    ///   - `.anime`  → `SRVGGNetCompact_Playback(.anime)`
    ///   - others    → `SRVGGNetCompact_Playback(.general)` (the C.4 A/B
    ///                 winner — `Backend.defaultGeneral`)
    ///
    /// Both presets now route to SRVGGNetCompact variants; EfRLFN is
    /// reachable only via the explicit `init(backend:)`.
    public convenience init(
        scale: Int = 4,
        preset: ForgeUpscaler.ContentPreset = .general
    ) throws {
        let backend: Backend = preset == .anime
            ? .srvggnetAnime(scale: scale)
            : .srvggnetGeneral(scale: scale)
        try self.init(backend: backend)
    }

    /// Convenience: identical signature to the old `(preset:scale:)` order
    /// some call sites used. Forwards to `init(scale:preset:)`.
    public convenience init(
        preset: ForgeUpscaler.ContentPreset,
        scale: Int = 4
    ) throws {
        try self.init(scale: scale, preset: preset)
    }

    // MARK: - Tier factory

    private static func makeTier(for backend: Backend) throws -> PlaybackTier {
        switch backend {
        case .efrlfn(let scale):
            return try EfRLFN_Playback(scale: scale)
        case .srvggnetGeneral:
            return try SRVGGNetCompact_Playback(variant: .general)
        case .srvggnetGeneralWDN:
            return try SRVGGNetCompact_Playback(variant: .generalWDN)
        case .srvggnetAnime:
            return try SRVGGNetCompact_Playback(variant: .anime)
        }
    }

    // MARK: - Inference

    /// Upscale a full frame using the active tier.
    ///
    /// `PlaybackTier.upscale(_:)` is async to leave room for future
    /// backends that run on their own queues; the MLX-Swift tiers we ship
    /// today are synchronous under the hood, so we block the calling
    /// thread on a semaphore for the result. This preserves the existing
    /// synchronous `PlaybackUpscaler.upscale(_:)` signature that
    /// `ForgeUpscaler.upscale(_:)` and the playback pipeline depend on.
    public func upscale(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
        // `CVPixelBuffer` is a CoreFoundation reference type and not formally
        // `Sendable`; we pass it through an `UnsafeBufferBox` to express the
        // single-crossing-point convention.
        let box = UnsafeBufferBox(input)
        let tierRef = tier
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<CVPixelBuffer, Error> =
            .failure(PlaybackTierError.inferenceError("uninitialised"))
        Task.detached {
            do {
                let out = try await tierRef.upscale(box.buffer)
                result = .success(out)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    /// Sendable wrapper for `CVPixelBuffer`. Marked `@unchecked Sendable`
    /// because callers must guarantee no concurrent access — `upscale(_:)`
    /// blocks on a semaphore around the only crossing point.
    private struct UnsafeBufferBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
        init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
    }
}
