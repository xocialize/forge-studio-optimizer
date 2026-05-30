import CoreML
import CoreVideo
import FormatBridge
import Foundation

/// DnCNN color denoiser — removes noise before encoding for better compression.
/// Input: [1, 3, 256, 256], Output: [1, 3, 256, 256]
/// Conforms to FormatBridge's FrameProcessor protocol for pipeline integration.
///
/// Phase A.3: the new async `init(registry:)` routes through `ModelRegistry`
/// (license-checked, cached). The legacy synchronous `init()` remains for
/// backward compatibility with `PreprocessorFactory.makeChain(for:)` callers
/// (e.g. `AppManager.convert`) and uses the legacy `CoreMLProcessor` loader.
public final class Denoiser: FrameProcessor, @unchecked Sendable {
    private let processor: CoreMLProcessor

    /// Legacy synchronous init. Loads `dncnn_color.mlpackage` directly
    /// from `Bundle.module`. Kept for backward compat; do not remove
    /// while `PreprocessorFactory.makeChain(for:)` is sync.
    public init() throws {
        self.processor = try CoreMLProcessor(modelName: "dncnn_color", inputSize: 256)
    }

    /// Phase A.3 init: load via `ModelRegistry` so the SPDX/license check
    /// runs before CoreML touches the file. Defaults to the process-wide
    /// `.bundled` registry (.development policy).
    public init(registry: ModelRegistry = .bundled) async throws {
        let loaded = try await registry.load(role: .denoise, implementation: "dncnn_color")
        let inputSize = loaded.manifest.inputSize ?? 256
        self.processor = CoreMLProcessor(model: loaded.model, inputSize: inputSize)
    }

    /// Process a CVPixelBuffer through the denoiser.
    /// For the FrameProcessor protocol, use processCVPixelBuffer directly.
    public func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        // For now, return the input unchanged if processing fails.
        // Full tiling implementation will be added when the pipeline is wired end-to-end.
        do {
            let input = try pixelBufferToMultiArray(pixelBuffer, channels: 3, size: 256)
            let output = try processor.predict(input: input)
            return try multiArrayToPixelBuffer(output, width: 256, height: 256)
        } catch {
            return pixelBuffer
        }
    }
}

/// DnCNN grayscale denoiser — luma-only denoising (lighter, faster).
/// Input: [1, 1, 256, 256], Output: [1, 1, 256, 256]
public final class GrayDenoiser: @unchecked Sendable {
    private let processor: CoreMLProcessor

    /// Legacy synchronous init. Loads `dncnn_gray.mlpackage` directly
    /// from `Bundle.module`.
    public init() throws {
        self.processor = try CoreMLProcessor(modelName: "dncnn_gray", inputSize: 256)
    }

    /// Phase A.3 init: load via `ModelRegistry`. See `Denoiser.init(registry:)`.
    public init(registry: ModelRegistry = .bundled) async throws {
        let loaded = try await registry.load(role: .denoise, implementation: "dncnn_gray")
        let inputSize = loaded.manifest.inputSize ?? 256
        self.processor = CoreMLProcessor(model: loaded.model, inputSize: inputSize)
    }
}
