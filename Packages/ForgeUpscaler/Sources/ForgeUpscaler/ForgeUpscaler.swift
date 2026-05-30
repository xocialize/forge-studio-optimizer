import CoreVideo
import Foundation

/// ForgeUpscaler — Three-tier AI super-resolution for video.
///
/// Tiers are a **quality/cost spectrum** (fast-light → slow-heavy), not a
/// realtime guarantee — realtime SR is a separate-project concern (ADR-0009).
/// The "Cost" column is informational, not a gate.
///
/// | Tier | Engine | Cost | Use Case |
/// |------|--------|------|----------|
/// | `.preview`  | MetalFX Spatial (no model)         | very fast | Timeline scrubbing |
/// | `.playback` | SRVGGNetCompact-general (MLX)      | fast      | Low-res → 4K enhancement |
/// | `.export`   | Real-ESRGAN CoreML (`ExportTier`)  | slow      | Offline, best quality |
///
/// ## Playback backend selection (Phase C.5a / C.4)
/// The playback tier dispatches through `PlaybackTier` and supports four
/// backends — three `SRVGGNetCompact_Playback` variants (BSD-3-Clause, general /
/// general-WDN / anime) and `EfRLFN_Playback` (MIT, ~504K params). The
/// content-preset initialisers route `.anime` to the SRVGGNetCompact anime
/// variant and everything else to **SRVGGNetCompact-general** — the Phase C.4
/// A/B winner (ADR-0008; EfRLFN was rejected). EfRLFN stays reachable via
/// `init(backend:)` for re-evaluation.
///
/// ## Usage
/// ```swift
/// // Quick preview
/// let preview = try ForgeUpscaler(tier: .preview, inputSize: (1920, 1080), outputSize: (3840, 2160))
/// let upscaled = try preview.upscale(pixelBuffer)
///
/// // Playback with explicit backend (e.g. for the C.4 A/B runner)
/// let playback = try ForgeUpscaler(backend: .srvggnetGeneral(scale: 4), temporalConsistency: true)
///
/// // Full video export
/// let exporter = try ForgeUpscaler(tier: .export, modelURL: rrdbnetURL)
/// try await exporter.exportVideo(input: inputURL, output: outputURL)
/// ```
public final class ForgeUpscaler: @unchecked Sendable {

    public enum Tier: Sendable {
        case preview     // MetalFX Spatial (no ML — fast)
        case playback    // SRVGGNetCompact-general MLX-Swift (fast tier; not realtime-gated, ADR-0009)
        case export      // Real-ESRGAN CoreML (slow, maximum quality)
    }

    public enum ContentPreset: String, Sendable {
        case general
        case anime
        case signage
        case dvd
    }

    private let tier: Tier
    private var metalFX: MetalFXUpscaler?
    private var playbackUpscaler: PlaybackUpscaler?
    private var exportUpscaler: ExportUpscaler?
    private var exportPipeline: ExportPipeline?

    /// Initialize for preview tier (MetalFX, no ML model needed).
    public init(
        tier: Tier = .preview,
        inputSize: (width: Int, height: Int),
        outputSize: (width: Int, height: Int)
    ) throws {
        self.tier = tier

        switch tier {
        case .preview:
            self.metalFX = try MetalFXUpscaler(
                inputWidth: inputSize.width,
                inputHeight: inputSize.height,
                outputWidth: outputSize.width,
                outputHeight: outputSize.height
            )
        default:
            throw UpscalerError.invalidConfiguration("Use init(tier:modelURL:) for ML-based tiers")
        }
    }

    /// Initialize for playback or export tier with a CoreML model URL.
    public init(
        tier: Tier,
        modelURL: URL,
        scale: Int = 4,
        temporalConsistency: Bool = true
    ) throws {
        self.tier = tier

        switch tier {
        case .preview:
            throw UpscalerError.invalidConfiguration("Preview tier doesn't need a model URL")

        case .playback:
            // The legacy `modelURL`-based playback path expected a CoreML
            // SRVGGNetCompact mlpackage that was never vendored. The Phase
            // C.5a refactor replaces this with the `Backend` enum — callers
            // should use `init(backend:)` or `init(tier:preset:scale:)`.
            _ = modelURL
            throw UpscalerError.invalidConfiguration(
                "Playback tier no longer accepts a modelURL; use init(backend:) or init(tier: .playback, preset:) instead"
            )

        case .export:
            let upscaler = try ExportUpscaler(
                modelURL: modelURL, scale: scale,
                tileSize: 400, tileOverlap: 32
            )
            self.exportUpscaler = upscaler

            let blender = temporalConsistency ? TemporalBlender() : nil
            self.exportPipeline = ExportPipeline(upscaler: upscaler, temporalBlender: blender)
        }
    }

    /// Initialize for playback tier with an explicit `PlaybackUpscaler.Backend`.
    ///
    /// Use this from the Phase C.4 A/B benchmark runner or any caller that
    /// wants to pin a specific backend (`.efrlfn(scale:)`,
    /// `.srvggnetGeneral(scale:)`, `.srvggnetGeneralWDN(scale:)`,
    /// `.srvggnetAnime(scale:)`). The preset-based initialiser below picks
    /// a reasonable default per content type if you don't care.
    ///
    /// ```swift
    /// // C.4 A/B runner — pin EfRLFN x4.
    /// let efrlfn = try ForgeUpscaler(backend: .efrlfn(scale: 4))
    /// // C.4 A/B runner — pin SRVGGNetCompact general x4 baseline.
    /// let srv    = try ForgeUpscaler(backend: .srvggnetGeneral(scale: 4))
    /// ```
    public init(
        backend: PlaybackUpscaler.Backend,
        temporalConsistency: Bool = true
    ) throws {
        self.tier = .playback
        _ = temporalConsistency  // playback tier doesn't currently consume
                                 // the temporal flag; reserved for the
                                 // C.5b TemporalBlender integration.
        self.playbackUpscaler = try PlaybackUpscaler(backend: backend)
    }

    /// Initialize for playback or export tier using bundled models with a content preset.
    ///
    /// ```swift
    /// // Real-time playback upscaling for anime
    /// let upscaler = try ForgeUpscaler(tier: .playback, preset: .anime)
    ///
    /// // Max quality export for general content
    /// let upscaler = try ForgeUpscaler(tier: .export, preset: .general)
    /// ```
    public init(
        tier: Tier,
        preset: ContentPreset = .general,
        scale: Int = 4,
        temporalConsistency: Bool = true
    ) throws {
        self.tier = tier

        switch tier {
        case .preview:
            throw UpscalerError.invalidConfiguration("Preview tier doesn't use presets — use init(tier:inputSize:outputSize:)")

        case .playback:
            self.playbackUpscaler = try PlaybackUpscaler(preset: preset, scale: scale)

        case .export:
            let upscaler = try ExportUpscaler(preset: preset, scale: scale)
            self.exportUpscaler = upscaler

            let blender = temporalConsistency ? TemporalBlender() : nil
            self.exportPipeline = ExportPipeline(upscaler: upscaler, temporalBlender: blender)
        }
    }

    // MARK: - Single Frame

    /// Upscale a single frame using the configured tier.
    public func upscale(_ pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        switch tier {
        case .preview:
            guard let metalFX else { throw UpscalerError.notInitialized }
            return try metalFX.upscale(pixelBuffer)
        case .playback:
            guard let playback = playbackUpscaler else { throw UpscalerError.notInitialized }
            return try playback.upscale(pixelBuffer)
        case .export:
            guard let export = exportUpscaler else { throw UpscalerError.notInitialized }
            return try export.upscale(pixelBuffer)
        }
    }

    // MARK: - Full Video Export

    /// Export an entire video with upscaling (export tier only).
    public func exportVideo(
        inputURL: URL,
        outputURL: URL,
        progress: @escaping @Sendable (ExportPipeline.ExportProgress) -> Void
    ) async throws {
        guard let pipeline = exportPipeline else {
            throw UpscalerError.invalidConfiguration("Export pipeline only available with .export tier")
        }
        try await pipeline.processVideo(
            inputURL: inputURL, outputURL: outputURL, progress: progress
        )
    }
}

// MARK: - Errors

public enum UpscalerError: Error, CustomStringConvertible {
    case noMetalDevice
    case commandQueueFailed
    case commandBufferFailed
    case scalerCreationFailed
    case textureCreationFailed
    case bufferCreationFailed
    case modelNotFound(String)
    case noVideoStream
    case invalidConfiguration(String)
    case notInitialized

    public var description: String {
        switch self {
        case .noMetalDevice: return "No Metal GPU device available"
        case .commandQueueFailed: return "Failed to create Metal command queue"
        case .commandBufferFailed: return "Failed to create Metal command buffer"
        case .scalerCreationFailed: return "Failed to create MetalFX spatial scaler"
        case .textureCreationFailed: return "Failed to create Metal texture"
        case .bufferCreationFailed: return "Failed to create CVPixelBuffer"
        case .modelNotFound(let name): return "CoreML model not found: \(name)"
        case .noVideoStream: return "No video stream in input file"
        case .invalidConfiguration(let msg): return "Invalid configuration: \(msg)"
        case .notInitialized: return "Upscaler not initialized for this tier"
        }
    }
}
