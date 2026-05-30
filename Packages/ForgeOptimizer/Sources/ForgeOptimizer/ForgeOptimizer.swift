import CoreVideo
import Foundation
import MLX
import MLXNN

/// ForgeOptimizer — AI-driven video analysis using LiteFlowNet optical flow.
///
/// Analyzes video frames for motion patterns, scene changes, and complexity
/// to guide adaptive encoding decisions in the Forge conversion pipeline.
///
/// ## Usage
/// ```swift
/// let optimizer = try ForgeOptimizer(weightsURL: weightsPath)
///
/// // Analyze sequential frames
/// let result1 = try optimizer.analyzeFrame(frame1, frameIndex: 0)
/// let result2 = try optimizer.analyzeFrame(frame2, frameIndex: 1)
///
/// // Use results to guide encoding
/// print(result2.motionScore)     // 0.0 (static) to 1.0 (high motion)
/// print(result2.qpAdjustment)    // -6 to +4 QP offset recommendation
/// print(result2.isSceneChange)   // true at scene boundaries
/// ```
public final class ForgeOptimizer: @unchecked Sendable {

    private let model: LiteFlowNet
    private var previousFrame: MLXArray?
    private var frameCount: Int = 0

    /// Initialize ForgeOptimizer with trained LiteFlowNet weights.
    /// - Parameter weightsURL: Path to `.safetensors` weight file
    public init(weightsURL: URL) throws {
        model = LiteFlowNet()

        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw ForgeOptimizerError.weightsNotFound(weightsURL.path)
        }

        let arrays = try MLX.loadArrays(url: weightsURL)
        let parameters = ModuleParameters.unflattened(arrays)
        try model.update(parameters: parameters, verify: .noUnusedKeys)
        MLX.eval(model.parameters())
    }

    /// Analyze a video frame by computing optical flow from the previous frame.
    ///
    /// The first frame in a sequence produces a baseline result (no flow).
    /// Subsequent frames compute flow relative to the previous frame.
    ///
    /// - Parameters:
    ///   - pixelBuffer: BGRA CVPixelBuffer from the video decoder
    ///   - frameIndex: Index of this frame in the sequence
    /// - Returns: Motion analysis result with metrics and encoding recommendations
    public func analyzeFrame(
        _ pixelBuffer: CVPixelBuffer,
        frameIndex: Int
    ) -> AnalysisResult {
        let currentFrame = PixelBufferBridge.toMLXArray(pixelBuffer, isFirstFrame: previousFrame == nil)

        guard let prevFrame = previousFrame else {
            // First frame — no flow to compute
            previousFrame = currentFrame
            frameCount = 1
            return AnalysisResult(
                frameIndex: frameIndex,
                meanMagnitude: 0,
                maxMagnitude: 0,
                p95Magnitude: 0,
                motionScore: 0,
                movingPixelRatio: 0,
                isSceneChange: false,
                qpAdjustment: 0
            )
        }

        // Pad both frames to 32× multiples
        let (img1Padded, _, _) = PixelBufferBridge.padToMultiple32(prevFrame)
        let (img2Padded, _, _) = PixelBufferBridge.padToMultiple32(currentFrame)

        // Run optical flow inference
        let flow = model(img1Padded, img2Padded)
        MLX.eval(flow)

        // Analyze flow
        let result = MotionAnalyzer.analyze(flow: flow, frameIndex: frameIndex)

        // Update state
        previousFrame = currentFrame
        frameCount += 1

        return result
    }

    /// Reset state between videos.
    public func reset() {
        previousFrame = nil
        frameCount = 0
    }
}

/// Errors from ForgeOptimizer.
public enum ForgeOptimizerError: Error, CustomStringConvertible {
    case weightsNotFound(String)
    case modelLoadFailed(String)

    public var description: String {
        switch self {
        case .weightsNotFound(let path):
            return "Weights file not found: \(path)"
        case .modelLoadFailed(let detail):
            return "Failed to load model: \(detail)"
        }
    }
}
