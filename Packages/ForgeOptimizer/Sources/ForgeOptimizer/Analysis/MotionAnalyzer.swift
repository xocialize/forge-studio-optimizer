import MLX

/// Extracts motion metrics from optical flow fields.
enum MotionAnalyzer {

    /// Motion threshold: pixels with magnitude above this are "moving".
    static let motionThreshold: Float = 1.0

    /// Scene change threshold: mean magnitude above this indicates a cut.
    static let sceneChangeThreshold: Float = 30.0

    /// Normalization cap for motion score (pixels of flow magnitude → 0-1 score).
    static let maxMotionForScoring: Float = 50.0

    /// Analyze an optical flow field and produce motion metrics.
    /// - Parameters:
    ///   - flow: [1, H, W, 2] optical flow (u, v in pixels, already scaled by 20.0)
    ///   - frameIndex: Index of this frame in the sequence
    /// - Returns: AnalysisResult with motion metrics
    static func analyze(flow: MLXArray, frameIndex: Int) -> AnalysisResult {
        // Compute per-pixel magnitude: sqrt(u² + v²)
        let flowSq = flow * flow
        let magSq = MLX.sum(flowSq, axis: -1)  // [1, H, W]
        let magnitude = MLX.sqrt(magSq + 1e-8)

        MLX.eval(magnitude)

        // Extract statistics
        let meanMag = Float(MLX.mean(magnitude).item(Float.self))
        let maxMag = Float(MLX.max(magnitude).item(Float.self))

        // 95th percentile via sorted values
        let flat = magnitude.reshaped([-1])
        let sorted = MLX.sorted(flat)
        let p95Idx = Int(Float(sorted.shape[0]) * 0.95)
        let p95Mag = Float(sorted[p95Idx].item(Float.self))

        // Motion score: normalized mean magnitude
        let motionScore = min(meanMag / maxMotionForScoring, 1.0)

        // Moving pixel ratio
        let movingMask = magnitude .> motionThreshold
        let movingRatio = Float(MLX.mean(movingMask.asType(.float32)).item(Float.self))

        // Scene change detection
        let isSceneChange = meanMag > sceneChangeThreshold

        // QP adjustment recommendation
        let qpAdjustment: Int
        if isSceneChange {
            qpAdjustment = -6  // Much higher quality at scene boundaries
        } else if motionScore < 0.05 {
            qpAdjustment = 4   // Static content — can compress more
        } else if motionScore < 0.2 {
            qpAdjustment = 2   // Low motion
        } else if motionScore > 0.7 {
            qpAdjustment = -2  // High motion — preserve quality
        } else {
            qpAdjustment = 0   // Normal
        }

        return AnalysisResult(
            frameIndex: frameIndex,
            meanMagnitude: meanMag,
            maxMagnitude: maxMag,
            p95Magnitude: p95Mag,
            motionScore: motionScore,
            movingPixelRatio: movingRatio,
            isSceneChange: isSceneChange,
            qpAdjustment: qpAdjustment
        )
    }
}
