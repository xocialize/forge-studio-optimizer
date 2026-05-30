import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Shared CIContext for the pixel-format normalisation below. Building a
/// CIContext is expensive; keep one alive for the process lifetime.
private let sharedNormalizeContext = CIContext(options: [.cacheIntermediates: false])

/// Ensure a packed 32BGRA `CVPixelBuffer`.
///
/// CRITICAL: `FFmpegDecoder` emits **NV12** (biplanar YUV), but every
/// byte-level reader in this module (`pixelBufferToMultiArray` here, and
/// `PixelBufferBridge.toMLXArray` for LiteFlowNet) indexes the buffer as
/// packed 4-byte BGRA. Handed an NV12 buffer they read the Y (luma) plane as
/// BGRA → sheared, grayscale garbage — the same defect that broke the
/// ForgeUpscaler playback tier (commit e06ff85). CoreImage decodes NV12 → RGB
/// with the correct YCbCr matrix + video-range expansion; a buffer that is
/// already BGRA passes straight through.
func ensureBGRA(_ input: CVPixelBuffer) -> CVPixelBuffer {
    if CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA {
        return input
    }
    let width = CVPixelBufferGetWidth(input)
    let height = CVPixelBufferGetHeight(input)
    var out: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                              attrs as CFDictionary, &out) == kCVReturnSuccess,
          let bgra = out else { return input }
    sharedNormalizeContext.render(CIImage(cvPixelBuffer: input), to: bgra)
    return bgra
}

/// Convert a CVPixelBuffer to an MLMultiArray for CoreML inference.
/// Handles BGRA → RGB conversion and resizing to the model's expected input size.
///
/// - Parameters:
///   - rawPixelBuffer: CVPixelBuffer from the decoder (NV12 or BGRA);
///     normalised to BGRA up front via `ensureBGRA`.
///   - channels: Number of channels (3 for color, 1 for gray)
///   - size: Target spatial dimension (square, e.g. 256)
/// - Returns: [1, channels, size, size] MLMultiArray (NCHW, float32)
func pixelBufferToMultiArray(
    _ rawPixelBuffer: CVPixelBuffer,
    channels: Int,
    size: Int
) throws -> MLMultiArray {
    let pixelBuffer = ensureBGRA(rawPixelBuffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw ForgeOptimizerError.modelLoadFailed("Cannot access pixel buffer base address")
    }

    let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

    let array = try MLMultiArray(shape: [1, channels as NSNumber, size as NSNumber, size as NSNumber],
                                  dataType: .float32)

    // Scale factors for sampling from the source
    let scaleX = Float(width) / Float(size)
    let scaleY = Float(height) / Float(size)

    for y in 0 ..< size {
        let srcY = min(Int(Float(y) * scaleY), height - 1)
        for x in 0 ..< size {
            let srcX = min(Int(Float(x) * scaleX), width - 1)
            let srcOffset = srcY * bytesPerRow + srcX * 4

            // BGRA → RGB, normalize to [0, 1]
            let b = Float(srcPtr[srcOffset + 0]) / 255.0
            let g = Float(srcPtr[srcOffset + 1]) / 255.0
            let r = Float(srcPtr[srcOffset + 2]) / 255.0

            if channels == 3 {
                // NCHW layout: [1, C, H, W]
                array[[0, 0, y, x] as [NSNumber]] = NSNumber(value: r)
                array[[0, 1, y, x] as [NSNumber]] = NSNumber(value: g)
                array[[0, 2, y, x] as [NSNumber]] = NSNumber(value: b)
            } else {
                // Grayscale: luminance
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                array[[0, 0, y, x] as [NSNumber]] = NSNumber(value: lum)
            }
        }
    }

    return array
}

/// Convert an MLMultiArray output back to a CVPixelBuffer.
/// Assumes NCHW layout [1, 3, H, W] with values in [0, 1].
///
/// - Parameters:
///   - array: [1, 3, H, W] MLMultiArray (float32)
///   - width: Output pixel buffer width
///   - height: Output pixel buffer height
/// - Returns: BGRA CVPixelBuffer
func multiArrayToPixelBuffer(
    _ array: MLMultiArray,
    width: Int,
    height: Int
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]

    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                      attrs as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
        throw ForgeOptimizerError.modelLoadFailed("Failed to create output pixel buffer")
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    let dstPtr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

    for y in 0 ..< height {
        for x in 0 ..< width {
            // NCHW: [1, C, y, x]
            let r = max(0, min(1, array[[0, 0, y, x] as [NSNumber]].floatValue))
            let g = max(0, min(1, array[[0, 1, y, x] as [NSNumber]].floatValue))
            let b = max(0, min(1, array[[0, 2, y, x] as [NSNumber]].floatValue))

            let offset = y * bytesPerRow + x * 4
            dstPtr[offset + 0] = UInt8(b * 255)  // B
            dstPtr[offset + 1] = UInt8(g * 255)  // G
            dstPtr[offset + 2] = UInt8(r * 255)  // R
            dstPtr[offset + 3] = 255              // A
        }
    }

    return buffer
}
