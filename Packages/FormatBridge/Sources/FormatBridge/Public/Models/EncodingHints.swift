import CoreMedia
import Foundation

/// Per-frame analysis metadata, produced by ForgeOptimizer's analysis pass.
/// Stored as JSON during Pass 1, loaded during Pass 2.
public struct FrameMetadata: Codable, Sendable {
    public let index: Int
    public let presentationTime: Int64
    public let roiMaskPath: String?
    public let roiBoundingBoxes: [ROIBox]?
    public let motionScore: Float
    public let complexityScore: Float
    public let recommendedParams: EncodingHints

    public init(
        index: Int,
        presentationTime: Int64,
        roiMaskPath: String?,
        roiBoundingBoxes: [ROIBox]?,
        motionScore: Float,
        complexityScore: Float,
        recommendedParams: EncodingHints
    ) {
        self.index = index
        self.presentationTime = presentationTime
        self.roiMaskPath = roiMaskPath
        self.roiBoundingBoxes = roiBoundingBoxes
        self.motionScore = motionScore
        self.complexityScore = complexityScore
        self.recommendedParams = recommendedParams
    }
}

/// Per-frame encoding guidance from the AI analysis pipeline.
public struct EncodingHints: Codable, Sendable {
    public let bitrateMultiplier: Float
    public let canDropFrame: Bool
    public let roiQPOffset: Int
    public let useLongGOP: Bool
    public let forceKeyframe: Bool

    public init(
        bitrateMultiplier: Float = 1.0,
        canDropFrame: Bool = false,
        roiQPOffset: Int = 0,
        useLongGOP: Bool = false,
        forceKeyframe: Bool = false
    ) {
        self.bitrateMultiplier = bitrateMultiplier
        self.canDropFrame = canDropFrame
        self.roiQPOffset = roiQPOffset
        self.useLongGOP = useLongGOP
        self.forceKeyframe = forceKeyframe
    }

    public static let `default` = EncodingHints()
}

public struct ROIBox: Codable, Sendable {
    public let x: Float
    public let y: Float
    public let width: Float
    public let height: Float
    public let label: String?
    public let confidence: Float

    public init(x: Float, y: Float, width: Float, height: Float, label: String?, confidence: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.label = label
        self.confidence = confidence
    }
}
