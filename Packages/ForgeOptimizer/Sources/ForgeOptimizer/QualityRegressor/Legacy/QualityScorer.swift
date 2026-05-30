import CoreML
import CoreVideo
import Foundation

/// Quality regressor — predicts perceptual quality score (0-100) for a frame.
/// Used in Pass 1 analysis alongside LiteFlowNet motion scoring.
/// Input: [1, 3, 224, 224], Output: [1, 1] (scalar quality score)
///
/// Phase A.3: new `init(registry:)` routes through `ModelRegistry`. The
/// weights are SPDX `Proprietary-Research` (KADID-10k-derived); the
/// `.commercial` policy will refuse this load until Phase E.5 replaces
/// the head with a SigLIP2 NR-IQA implementation (Apache-2.0).
public final class QualityScorer: @unchecked Sendable {
    private let processor: CoreMLProcessor

    /// Legacy synchronous init.
    public init() throws {
        self.processor = try CoreMLProcessor(modelName: "quality_regressor", inputSize: 224)
    }

    /// Phase A.3 init: load via `ModelRegistry`. Will throw
    /// `ModelRegistryError.licenseRefused` under `.commercial` policy.
    public init(registry: ModelRegistry = .bundled) async throws {
        let loaded = try await registry.load(role: .qualityRegressor, implementation: "quality_regressor")
        let inputSize = loaded.manifest.inputSize ?? 224
        self.processor = CoreMLProcessor(model: loaded.model, inputSize: inputSize)
    }

    /// Score a frame's perceptual quality.
    /// Returns a value in [0, 100] where higher = better quality.
    public func score(_ pixelBuffer: CVPixelBuffer) -> Float {
        do {
            let input = try pixelBufferToMultiArray(pixelBuffer, channels: 3, size: 224)
            let output = try processor.predict(input: input)
            return output[0].floatValue
        } catch {
            return 50.0  // Default mid-range score on failure
        }
    }
}
