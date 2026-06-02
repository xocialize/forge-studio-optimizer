import CoreVideo
import FormatBridge
import Foundation

/// decode → (optional) `FrameProcessor` → encode. The processor is ForgeOptimizer's
/// chain reused unchanged; `nil` is a passthrough. Phase 1 handles stills (1 frame);
/// animated/multi-page sequence assembly is Phase 3 (PRD §7).
final class StillConversionOrchestratorImpl: StillConversionOrchestrating, @unchecked Sendable {

    private let decoder: any StillDecoding
    private let encoder: any StillEncoding

    init(decoder: any StillDecoding, encoder: any StillEncoding) {
        self.decoder = decoder
        self.encoder = encoder
    }

    func convert(input: URL, output: URL, settings: StillEncoderSettings,
                 frameProcessor: (any FrameProcessor)?) throws {
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ImageBridgeError.fileNotFound(input.path)
        }
        let (frames, meta) = try decoder.decode(url: input)
        guard let first = frames.first else { throw ImageBridgeError.decodeFailed("no frames decoded") }
        if meta.frameCount > 1 {
            // TODO(Phase 3): run the processor per frame + assemble the sequence
            // (optimized GIF/APNG/animated-WebP, or transcode to HEVC/AV1 via
            // FormatBridge). Phase 1 emits the first frame only.
        }
        // Alpha note (PRD §4): the AI models are opaque-RGB; alpha unassociate /
        // recombine is Phase 3. Passthrough (nil processor) preserves alpha as-is.
        let processed = frameProcessor?.process(first) ?? first
        try encoder.encode(processed, settings: settings, metadata: meta, to: output)
    }
}
