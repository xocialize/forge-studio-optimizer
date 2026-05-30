import Foundation

/// Per-frame motion analysis result. Sendable — safe to pass across actor boundaries.
public struct AnalysisResult: Sendable {
    /// Frame index in the video sequence.
    public let frameIndex: Int

    /// Mean flow magnitude (pixels). 0 = static, higher = more motion.
    public let meanMagnitude: Float

    /// Maximum flow magnitude (pixels).
    public let maxMagnitude: Float

    /// 95th percentile flow magnitude.
    public let p95Magnitude: Float

    /// Motion score normalized to [0, 1].
    /// 0.0 = completely static, 1.0 = extreme motion.
    public let motionScore: Float

    /// Fraction of pixels with significant motion (magnitude > threshold).
    public let movingPixelRatio: Float

    /// Whether this frame is a scene change (large flow discontinuity).
    public let isSceneChange: Bool

    /// Recommended QP offset for encoding.
    /// Negative = higher quality (for scene changes), positive = lower quality (for static).
    public let qpAdjustment: Int
}
