import CoreVideo
import FormatBridge
import Foundation

// End-to-end "smart optimize" for a still (PRD §6, Phase 4) — the still analog of the
// video VMAF-targeted pipeline. Composes the pieces already built: decode → optional
// alpha-aware restoration (the injected FrameProcessor: ForgeOptimizer's IQA-gated,
// tiled NAFNet chain) → encode. For LOSSY formats the encode is a perceptual-floor
// search (smallest file clearing the injected `StillQualityScoring`); for PNG it's the
// lossless oxipng pass. Metric + model are injected, so this stays MLX-free — the
// SigLIP2 wiring is a thin ImageBridgeForge convenience.

public struct StillOptimizationSettings: Sendable {
    public let format: StillOutputFormat
    /// Run the injected restoration FrameProcessor before encoding (no-op if none).
    public let restore: Bool
    /// Perceptual-floor search config (lossy formats only).
    public let search: StillQualityTargetSearch
    /// oxipng preset for the lossless PNG path.
    public let pngOptimizeLevel: UInt8
    /// Drop ICC/EXIF/DPI on write.
    public let stripMetadata: Bool

    public init(format: StillOutputFormat, restore: Bool = true,
                search: StillQualityTargetSearch = StillQualityTargetSearch(targetScore: 0.85),
                pngOptimizeLevel: UInt8 = 4, stripMetadata: Bool = false) {
        self.format = format
        self.restore = restore
        self.search = search
        self.pngOptimizeLevel = pngOptimizeLevel
        self.stripMetadata = stripMetadata
    }
}

public struct StillOptimizationResult: Sendable {
    public let outputBytes: Int
    public let restored: Bool
    public let lossless: Bool
    /// Search outcome for the lossy path; nil for the lossless PNG path.
    public let target: StillTargetResult?
}

/// decode → (restore) → quality-target / lossless encode. Single-frame: a multi-page
/// (PDF) / animated source optimizes frame 1 (use the orchestrator's `convertSequence`
/// / `AnimatedToVideoConverter` for the multi-frame dispositions).
public final class StillOptimizer: @unchecked Sendable {

    private let decoder: any StillDecoding
    private let encoder: any StillEncoding
    private let scorer: any StillQualityScoring
    private let frameProcessor: (any FrameProcessor)?

    public init(decoder: any StillDecoding, encoder: any StillEncoding,
                scorer: any StillQualityScoring, frameProcessor: (any FrameProcessor)?) {
        self.decoder = decoder
        self.encoder = encoder
        self.scorer = scorer
        self.frameProcessor = frameProcessor
    }

    @discardableResult
    public func optimize(input: URL, output: URL, settings: StillOptimizationSettings) throws -> StillOptimizationResult {
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ImageBridgeError.fileNotFound(input.path)
        }
        let (frames, meta) = try decoder.decode(url: input)
        guard let first = frames.first else { throw ImageBridgeError.decodeFailed("no frames decoded") }

        // Restoration is alpha-aware (FrameRun un-premultiplies → processes opaque → recombines).
        let buffer = settings.restore ? FrameRun.run(first, processor: frameProcessor, alpha: meta.alpha) : first
        let didRestore = settings.restore && frameProcessor != nil
        let metaForEncode = settings.stripMetadata ? nil : meta

        if settings.format == .png {
            // Lossless: oxipng. Pixels preserved exactly; nothing to perceptually search.
            try encoder.encode(buffer,
                settings: StillEncoderSettings(format: .png, stripMetadata: settings.stripMetadata,
                                               losslessOptimize: true, optimizeLevel: settings.pngOptimizeLevel),
                metadata: metaForEncode, to: output)
            return StillOptimizationResult(outputBytes: Self.fileSize(output), restored: didRestore,
                                           lossless: true, target: nil)
        }

        // Lossy: smallest encode clearing the perceptual floor. Reference = the restored
        // buffer (what we're preserving), which is what a full-ref metric should compare
        // against; no-ref metrics (SigLIP2) ignore it.
        let qte = StillQualityTargetEncoder(encoder: encoder, decoder: decoder, scorer: scorer, search: settings.search)
        let target = try qte.encode(original: buffer, format: settings.format, metadata: metaForEncode, to: output)
        return StillOptimizationResult(outputBytes: target.bytes, restored: didRestore,
                                       lossless: false, target: target)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
