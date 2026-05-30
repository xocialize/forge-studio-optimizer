import CoreMedia
import Foundation

public struct ConversionProgress: Sendable {
    public let percentage: Double
    public let currentTime: CMTime
    public let totalDuration: CMTime
    public let framesProcessed: Int
    public let estimatedRemaining: TimeInterval?
    public let speed: Double
    public let stage: ConversionStage

    public init(
        percentage: Double,
        currentTime: CMTime,
        totalDuration: CMTime,
        framesProcessed: Int,
        estimatedRemaining: TimeInterval?,
        speed: Double,
        stage: ConversionStage
    ) {
        self.percentage = percentage
        self.currentTime = currentTime
        self.totalDuration = totalDuration
        self.framesProcessed = framesProcessed
        self.estimatedRemaining = estimatedRemaining
        self.speed = speed
        self.stage = stage
    }
}
