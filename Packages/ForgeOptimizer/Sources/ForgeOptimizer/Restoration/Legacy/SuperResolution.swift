import CoreML
import CoreVideo
import Foundation

/// ESPCN super-resolution — upscales frames for the "maximum" optimization trick.
/// Encode at lower resolution, then the decoder can optionally super-resolve.
///
/// ESPCN 2×: Input [1, 3, 128, 128] → Output [1, 3, 256, 256]
/// ESPCN 4×: Input [1, 3, 64, 64] → Output [1, 3, 256, 256]
///
/// Phase A.3: new `init(scaleFactor:registry:)` routes through `ModelRegistry`.
public final class SuperResolution: @unchecked Sendable {
    private let processor: CoreMLProcessor
    public let scaleFactor: Int

    /// Legacy synchronous init. Initialize with a scale factor (2 or 4).
    public init(scaleFactor: Int = 2) throws {
        let modelName = scaleFactor == 4 ? "espcn_x4" : "espcn_x2"
        let inputSize = scaleFactor == 4 ? 64 : 128
        self.scaleFactor = scaleFactor
        self.processor = try CoreMLProcessor(modelName: modelName, inputSize: inputSize)
    }

    /// Phase A.3 init: load via `ModelRegistry`. `scaleFactor` selects
    /// `.superResolution2x` (default) or `.superResolution4x`.
    public init(scaleFactor: Int = 2, registry: ModelRegistry = .bundled) async throws {
        let role: ModelRole = scaleFactor == 4 ? .superResolution4x : .superResolution2x
        let implementation = scaleFactor == 4 ? "espcn_x4" : "espcn_x2"
        let loaded = try await registry.load(role: role, implementation: implementation)
        let inputSize = loaded.manifest.inputSize ?? (scaleFactor == 4 ? 64 : 128)
        self.scaleFactor = scaleFactor
        self.processor = CoreMLProcessor(model: loaded.model, inputSize: inputSize)
    }
}
