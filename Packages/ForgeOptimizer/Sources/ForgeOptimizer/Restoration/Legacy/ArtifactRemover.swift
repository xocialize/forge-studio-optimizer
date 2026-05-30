import CoreML
import CoreVideo
import FormatBridge
import Foundation

/// ARCNN compression artifact remover.
/// Removes blocking and ringing artifacts from compressed video frames.
/// Input: [1, 3, 256, 256], Output: [1, 3, 256, 256]
///
/// Used in Pass 2 (aggressive/maximum optimization) and optionally on tvOS for
/// playback-side enhancement of aggressively compressed content.
///
/// Phase A.3: new `init(registry:)` routes through `ModelRegistry`. Legacy
/// synchronous `init()` retained for `PreprocessorFactory.makeChain`.
public final class ArtifactRemover: FrameProcessor, @unchecked Sendable {
    private let processor: CoreMLProcessor

    /// Legacy synchronous init.
    public init() throws {
        self.processor = try CoreMLProcessor(modelName: "arcnn", inputSize: 256)
    }

    /// Phase A.3 init: load via `ModelRegistry`.
    public init(registry: ModelRegistry = .bundled) async throws {
        let loaded = try await registry.load(role: .artifactRemoval, implementation: "arcnn")
        let inputSize = loaded.manifest.inputSize ?? 256
        self.processor = CoreMLProcessor(model: loaded.model, inputSize: inputSize)
    }

    public func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        do {
            let input = try pixelBufferToMultiArray(pixelBuffer, channels: 3, size: 256)
            let output = try processor.predict(input: input)
            return try multiArrayToPixelBuffer(output, width: 256, height: 256)
        } catch {
            return pixelBuffer
        }
    }
}
