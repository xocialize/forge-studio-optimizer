import CoreVideo
import MLX

/// Converts between CVPixelBuffer (video frames) and MLXArray (model input/output).
public enum PixelBufferBridge {

    /// Per-channel means (BGR order) for preprocessing.
    private static let meanImg1: [Float] = [0.411618, 0.434631, 0.454253]
    private static let meanImg2: [Float] = [0.410782, 0.433645, 0.452793]

    /// Convert a BGRA CVPixelBuffer to a preprocessed MLXArray for LiteFlowNet.
    /// - Parameters:
    ///   - pixelBuffer: BGRA or NV12 CVPixelBuffer from video decoder
    ///   - isFirstFrame: true for frame 1 (uses meanImg1), false for frame 2
    /// - Returns: [1, H, W, 3] BGR float32, mean-subtracted
    public static func toMLXArray(
        _ rawPixelBuffer: CVPixelBuffer,
        isFirstFrame: Bool
    ) -> MLXArray {
        // Decoder emits NV12; the BGR reader below assumes packed BGRA.
        // Normalise first (see ensureBGRA in PixelBufferConversion.swift) —
        // otherwise LiteFlowNet motion analysis runs on a misread luma plane.
        let pixelBuffer = ensureBGRA(rawPixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!

        let mean = isFirstFrame ? meanImg1 : meanImg2

        // Convert BGRA → BGR float32 with mean subtraction
        var bgrData = [Float](repeating: 0, count: height * width * 3)
        let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

        for y in 0 ..< height {
            for x in 0 ..< width {
                let srcOffset = y * bytesPerRow + x * 4
                let dstOffset = (y * width + x) * 3

                // BGRA → BGR, normalize to [0, 1], subtract mean
                bgrData[dstOffset + 0] = Float(srcPtr[srcOffset + 0]) / 255.0 - mean[0]  // B
                bgrData[dstOffset + 1] = Float(srcPtr[srcOffset + 1]) / 255.0 - mean[1]  // G
                bgrData[dstOffset + 2] = Float(srcPtr[srcOffset + 2]) / 255.0 - mean[2]  // R
            }
        }

        return MLXArray(bgrData, [1, height, width, 3])
    }

    /// Pad an MLXArray to multiples of 32 for model input.
    /// - Returns: (padded array, original height, original width)
    public static func padToMultiple32(_ x: MLXArray) -> (MLXArray, Int, Int) {
        let shape = x.shape
        let h = shape[1]
        let w = shape[2]
        let padH = (32 - h % 32) % 32
        let padW = (32 - w % 32) % 32

        if padH == 0 && padW == 0 {
            return (x, h, w)
        }

        let padded = MLX.padded(x, widths: [IntOrPair((0, 0)), IntOrPair((0, padH)), IntOrPair((0, padW)), IntOrPair((0, 0))])
        return (padded, h, w)
    }
}
