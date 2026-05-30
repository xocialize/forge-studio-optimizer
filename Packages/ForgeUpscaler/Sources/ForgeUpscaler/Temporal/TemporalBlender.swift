import CoreVideo
import Foundation

/// Flow-guided temporal consistency for video upscaling.
///
/// Blends the current SR frame with the warped previous SR frame
/// to reduce flickering artifacts inherent to per-frame super-resolution.
///
/// Uses a simple exponential moving average with motion-adaptive blending:
/// - Static regions: heavy blending (α ≈ 0.4) → smooth, consistent
/// - Moving regions: light blending (α ≈ 0.1) → preserve motion detail
/// - Scene changes: no blending (α = 0) → instant transition
public final class TemporalBlender: @unchecked Sendable {

    /// Base blend factor: 0.0 = current only, 1.0 = previous only
    public let alpha: Float

    /// Scene change threshold (mean pixel difference)
    public let sceneChangeThreshold: Float

    public init(alpha: Float = 0.4, sceneChangeThreshold: Float = 0.15) {
        self.alpha = alpha
        self.sceneChangeThreshold = sceneChangeThreshold
    }

    /// Blend current SR frame with previous SR frame for temporal consistency.
    ///
    /// Simple version without optical flow — uses pixel-level blending with
    /// motion detection. For flow-guided blending, use `blend(current:previous:flow:scale:)`.
    ///
    /// - Parameters:
    ///   - current: Current frame's SR output
    ///   - previous: Previous frame's SR output
    /// - Returns: Temporally blended frame
    public func blend(current: CVPixelBuffer, previous: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(current)
        let height = CVPixelBufferGetHeight(current)

        // Check for scene change
        let diff = meanAbsoluteDifference(current, previous)
        if diff > sceneChangeThreshold {
            return current  // Scene change — no blending
        }

        // Adaptive alpha based on motion
        // More motion → less blending to avoid ghosting
        let motionFactor = min(diff / sceneChangeThreshold, 1.0)
        let adaptiveAlpha = alpha * (1.0 - motionFactor)

        // Blend pixel by pixel
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &outputBuffer)
        guard let output = outputBuffer else { return current }

        CVPixelBufferLockBaseAddress(current, .readOnly)
        CVPixelBufferLockBaseAddress(previous, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(current, .readOnly)
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        let curPtr = CVPixelBufferGetBaseAddress(current)!.assumingMemoryBound(to: UInt8.self)
        let prevPtr = CVPixelBufferGetBaseAddress(previous)!.assumingMemoryBound(to: UInt8.self)
        let outPtr = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)

        let curBPR = CVPixelBufferGetBytesPerRow(current)
        let prevBPR = CVPixelBufferGetBytesPerRow(previous)
        let outBPR = CVPixelBufferGetBytesPerRow(output)

        let oneMinusAlpha = 1.0 - adaptiveAlpha

        for y in 0 ..< height {
            for x in 0 ..< width {
                let curOff = y * curBPR + x * 4
                let prevOff = y * prevBPR + x * 4
                let outOff = y * outBPR + x * 4

                for c in 0 ..< 3 {
                    let cur = Float(curPtr[curOff + c])
                    let prev = Float(prevPtr[prevOff + c])

                    // Per-pixel motion: if pixel difference is large, reduce blending
                    let pixelDiff = abs(cur - prev) / 255.0
                    let pixelAlpha = adaptiveAlpha * max(0, 1.0 - pixelDiff * 5.0)

                    let blended = cur * (1.0 - pixelAlpha) + prev * pixelAlpha
                    outPtr[outOff + c] = UInt8(max(0, min(255, blended)))
                }
                outPtr[y * outBPR + x * 4 + 3] = 255 // Alpha
            }
        }

        return output
    }

    // MARK: - Flow-Guided Blending

    /// Blend with optical flow warping for ghost-free temporal consistency.
    ///
    /// Uses per-pixel flow vectors to warp the previous SR frame to align with
    /// the current frame before blending. Eliminates ghosting on moving objects
    /// that EMA blending cannot handle.
    ///
    /// - Parameters:
    ///   - current: Current frame's SR output
    ///   - previous: Previous frame's SR output
    ///   - flowU: Horizontal flow field [H, W] as Float buffer (pixels of motion)
    ///   - flowV: Vertical flow field [H, W] as Float buffer
    ///   - scale: Upscale factor (flow is at LR resolution, needs upscaling)
    /// - Returns: Temporally consistent SR frame
    public func blendWithFlow(
        current: CVPixelBuffer,
        previous: CVPixelBuffer,
        flowU: UnsafeBufferPointer<Float>,
        flowV: UnsafeBufferPointer<Float>,
        flowWidth: Int,
        flowHeight: Int,
        scale: Int
    ) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(current)
        let height = CVPixelBufferGetHeight(current)

        // Scene change detection
        let diff = meanAbsoluteDifference(current, previous)
        if diff > sceneChangeThreshold {
            return current
        }

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &outputBuffer)
        guard let output = outputBuffer else { return current }

        CVPixelBufferLockBaseAddress(current, .readOnly)
        CVPixelBufferLockBaseAddress(previous, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(current, .readOnly)
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        let curPtr = CVPixelBufferGetBaseAddress(current)!.assumingMemoryBound(to: UInt8.self)
        let prevPtr = CVPixelBufferGetBaseAddress(previous)!.assumingMemoryBound(to: UInt8.self)
        let outPtr = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let curBPR = CVPixelBufferGetBytesPerRow(current)
        let prevBPR = CVPixelBufferGetBytesPerRow(previous)
        let outBPR = CVPixelBufferGetBytesPerRow(output)

        for y in 0 ..< height {
            for x in 0 ..< width {
                // Map HR pixel to LR flow coordinates
                let fx = min(x / scale, flowWidth - 1)
                let fy = min(y / scale, flowHeight - 1)
                let flowIdx = fy * flowWidth + fx

                // Get flow vector and scale to HR space
                let u = flowU[flowIdx] * Float(scale)
                let v = flowV[flowIdx] * Float(scale)

                // Warp: sample previous frame at (x + u, y + v)
                let srcX = Int(Float(x) + u + 0.5)
                let srcY = Int(Float(y) + v + 0.5)

                let curOff = y * curBPR + x * 4
                let outOff = y * outBPR + x * 4

                // Flow magnitude → adaptive blend weight
                let flowMag = sqrt(u * u + v * v)
                let confidence = exp(-flowMag / 30.0)  // Less blending at large motions
                let blendWeight = alpha * confidence

                if srcX >= 0 && srcX < width && srcY >= 0 && srcY < height {
                    let prevOff = srcY * prevBPR + srcX * 4

                    for c in 0 ..< 3 {
                        let cur = Float(curPtr[curOff + c])
                        let prev = Float(prevPtr[prevOff + c])
                        let blended = cur * (1.0 - blendWeight) + prev * blendWeight
                        outPtr[outOff + c] = UInt8(max(0, min(255, blended)))
                    }
                } else {
                    // Out of bounds — use current frame only
                    for c in 0 ..< 3 {
                        outPtr[outOff + c] = curPtr[curOff + c]
                    }
                }
                outPtr[outOff + 3] = 255
            }
        }

        return output
    }

    // MARK: - Helpers

    private func meanAbsoluteDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Float {
        let width = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b))
        let height = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))

        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }

        let aPtr = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let bPtr = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let aBPR = CVPixelBufferGetBytesPerRow(a)
        let bBPR = CVPixelBufferGetBytesPerRow(b)

        // Sample a grid of pixels for fast estimation
        let sampleStep = max(width, height) / 32
        var totalDiff: Float = 0
        var count: Float = 0

        for y in stride(from: 0, to: height, by: max(sampleStep, 1)) {
            for x in stride(from: 0, to: width, by: max(sampleStep, 1)) {
                let aOff = y * aBPR + x * 4
                let bOff = y * bBPR + x * 4
                for c in 0 ..< 3 {
                    totalDiff += abs(Float(aPtr[aOff + c]) - Float(bPtr[bOff + c])) / 255.0
                }
                count += 3
            }
        }

        return count > 0 ? totalDiff / count : 0
    }
}
