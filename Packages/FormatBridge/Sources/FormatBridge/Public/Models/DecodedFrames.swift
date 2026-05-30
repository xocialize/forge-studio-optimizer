import CoreMedia
import CoreVideo

public struct DecodedVideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let duration: CMTime

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, duration: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.duration = duration
    }
}

public struct DecodedAudioBuffer: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public let presentationTime: CMTime

    public init(sampleBuffer: CMSampleBuffer, presentationTime: CMTime) {
        self.sampleBuffer = sampleBuffer
        self.presentationTime = presentationTime
    }
}
