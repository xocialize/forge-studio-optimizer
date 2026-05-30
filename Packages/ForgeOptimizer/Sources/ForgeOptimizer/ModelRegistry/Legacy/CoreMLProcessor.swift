import CoreML
import CoreVideo
import Foundation

/// Base class for CoreML frame processors.
/// Handles model loading, CVPixelBuffer tiling, and inference.
///
/// CoreML models have fixed input sizes (e.g. 256×256). For arbitrary resolution video frames,
/// we tile the frame into overlapping patches, run inference on each tile, and blend results.
///
/// Phase A.3: `ModelRegistry` now owns model loading; this class accepts a
/// pre-loaded `MLModel` via the new `init(model:inputSize:)` initializer.
/// The legacy `init(modelName:inputSize:)` path remains so the synchronous
/// `Denoiser.init()` / `ArtifactRemover.init()` / etc. constructors stay
/// byte-identical for existing `PreprocessorFactory.makeChain(for:)` callers.
class CoreMLProcessor {
    let model: MLModel
    let inputSize: Int
    let tileOverlap: Int

    /// Legacy loader path used by the synchronous public inits on
    /// `Denoiser`, `ArtifactRemover`, etc.
    init(modelName: String, inputSize: Int, tileOverlap: Int = 32) throws {
        guard let modelURL = Bundle.module.url(forResource: modelName, withExtension: "mlpackage") else {
            throw ForgeOptimizerError.weightsNotFound("CoreML model '\(modelName).mlpackage' not found in bundle")
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all  // Neural Engine + GPU + CPU
        self.model = try MLModel(contentsOf: MLModel.compileModel(at: modelURL), configuration: config)
        self.inputSize = inputSize
        self.tileOverlap = tileOverlap
    }

    /// Phase A.3 path: take a pre-loaded `MLModel` from `ModelRegistry`.
    init(model: MLModel, inputSize: Int, tileOverlap: Int = 32) {
        self.model = model
        self.inputSize = inputSize
        self.tileOverlap = tileOverlap
    }

    /// Run inference on a single tile.
    /// Input/output: [1, C, H, W] as MLMultiArray.
    func predict(input: MLMultiArray) throws -> MLMultiArray {
        let featureProvider = try MLDictionaryFeatureProvider(dictionary: ["input": input])
        let result = try model.prediction(from: featureProvider)
        guard let output = result.featureValue(for: result.featureNames.first ?? "output")?.multiArrayValue else {
            throw ForgeOptimizerError.modelLoadFailed("No output from CoreML model")
        }
        return output
    }
}
