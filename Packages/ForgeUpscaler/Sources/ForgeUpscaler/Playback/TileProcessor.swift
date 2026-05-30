import CoreML
import CoreVideo
import Foundation

/// Processes large frames by splitting into overlapping tiles,
/// running SR on each tile, and blending at seams.
///
/// For a 1920×1080 frame with 128×128 tiles and 16px overlap:
/// - Effective tile coverage: 112×112 pixels per tile
/// - Grid: ~18×10 = ~180 tiles
/// - At ~0.15ms per tile on Neural Engine ≈ ~27ms total
public struct TileProcessor: Sendable {

    let tileSize: Int
    let overlap: Int
    let scale: Int

    public init(tileSize: Int = 128, overlap: Int = 16, scale: Int = 4) {
        self.tileSize = tileSize
        self.overlap = overlap
        self.scale = scale
    }

    /// Process a full frame using tiled inference.
    public func process(_ input: CVPixelBuffer, model: MLModel) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let step = tileSize - overlap
        let outWidth = width * scale
        let outHeight = height * scale

        // Create output buffer
        var outputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outWidth,
            kCVPixelBufferHeightKey as String: outHeight,
        ]
        CVPixelBufferCreate(nil, outWidth, outHeight, kCVPixelFormatType_32BGRA,
                           attrs as CFDictionary, &outputBuffer)
        guard let output = outputBuffer else {
            throw UpscalerError.bufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(input, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(input, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        let srcPtr = CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to: UInt8.self)
        let srcBPR = CVPixelBufferGetBytesPerRow(input)
        let dstPtr = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let dstBPR = CVPixelBufferGetBytesPerRow(output)

        // Process tiles
        for tileY in stride(from: 0, to: height, by: step) {
            for tileX in stride(from: 0, to: width, by: step) {
                // Clamp tile position
                let x = min(tileX, max(0, width - tileSize))
                let y = min(tileY, max(0, height - tileSize))
                let tw = min(tileSize, width - x)
                let th = min(tileSize, height - y)

                // Extract tile
                let tileArray = try extractTileAsMultiArray(srcPtr, srcBPR: srcBPR,
                                                            x: x, y: y, tw: tw, th: th)

                // Run SR model
                let featureProvider = try MLDictionaryFeatureProvider(dictionary: ["input": tileArray])
                let result = try model.prediction(from: featureProvider)

                guard let outputArray = result.featureValue(for: result.featureNames.first ?? "output")?.multiArrayValue else {
                    continue
                }

                // Write upscaled tile to output (with overlap blending)
                writeTile(outputArray, to: dstPtr, dstBPR: dstBPR,
                         x: x * scale, y: y * scale,
                         tw: tw * scale, th: th * scale,
                         outWidth: outWidth, outHeight: outHeight,
                         overlapScaled: overlap * scale)
            }
        }

        return output
    }

    // MARK: - Tile Extraction

    private func extractTileAsMultiArray(
        _ src: UnsafePointer<UInt8>,
        srcBPR: Int,
        x: Int, y: Int, tw: Int, th: Int
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 3, tileSize as NSNumber, tileSize as NSNumber],
                                      dataType: .float32)

        for ty in 0 ..< tileSize {
            let srcY = min(y + ty, y + th - 1)
            for tx in 0 ..< tileSize {
                let srcX = min(x + tx, x + tw - 1)
                let offset = srcY * srcBPR + srcX * 4

                // BGRA → RGB, normalize to [0, 1]
                let b = Float(src[offset + 0]) / 255.0
                let g = Float(src[offset + 1]) / 255.0
                let r = Float(src[offset + 2]) / 255.0

                array[[0, 0, ty, tx] as [NSNumber]] = NSNumber(value: r)
                array[[0, 1, ty, tx] as [NSNumber]] = NSNumber(value: g)
                array[[0, 2, ty, tx] as [NSNumber]] = NSNumber(value: b)
            }
        }

        return array
    }

    // MARK: - Tile Writing with Feathered Overlap Blending

    private func writeTile(
        _ src: MLMultiArray,
        to dst: UnsafeMutablePointer<UInt8>,
        dstBPR: Int,
        x: Int, y: Int, tw: Int, th: Int,
        outWidth: Int, outHeight: Int,
        overlapScaled: Int
    ) {
        let srcH = src.shape[2].intValue
        let srcW = src.shape[3].intValue
        let ov = max(overlapScaled, 1)

        for ty in 0 ..< min(srcH, th) {
            let dstY = y + ty
            guard dstY < outHeight else { continue }

            for tx in 0 ..< min(srcW, tw) {
                let dstX = x + tx
                guard dstX < outWidth else { continue }

                // Get RGB values, clamp to [0, 1]
                let r = max(0, min(1, src[[0, 0, ty, tx] as [NSNumber]].floatValue))
                let g = max(0, min(1, src[[0, 1, ty, tx] as [NSNumber]].floatValue))
                let b = max(0, min(1, src[[0, 2, ty, tx] as [NSNumber]].floatValue))

                // Compute feather weight: 1.0 in center, ramps to 0.0 at overlap edges
                let wxLeft  = min(Float(tx) / Float(ov), 1.0)
                let wxRight = min(Float(srcW - 1 - tx) / Float(ov), 1.0)
                let wyTop   = min(Float(ty) / Float(ov), 1.0)
                let wyBot   = min(Float(srcH - 1 - ty) / Float(ov), 1.0)
                let weight  = min(wxLeft, wxRight) * min(wyTop, wyBot)

                let offset = dstY * dstBPR + dstX * 4

                if weight >= 0.999 {
                    // Center of tile — hard write (most pixels)
                    dst[offset + 0] = UInt8(b * 255)
                    dst[offset + 1] = UInt8(g * 255)
                    dst[offset + 2] = UInt8(r * 255)
                    dst[offset + 3] = 255
                } else {
                    // Overlap region — blend with existing pixel
                    let existB = Float(dst[offset + 0]) / 255.0
                    let existG = Float(dst[offset + 1]) / 255.0
                    let existR = Float(dst[offset + 2]) / 255.0

                    // If existing pixel is black (not yet written), just write
                    if dst[offset + 3] == 0 {
                        dst[offset + 0] = UInt8(b * 255)
                        dst[offset + 1] = UInt8(g * 255)
                        dst[offset + 2] = UInt8(r * 255)
                        dst[offset + 3] = 255
                    } else {
                        // Weighted blend
                        let blendR = existR * (1.0 - weight) + r * weight
                        let blendG = existG * (1.0 - weight) + g * weight
                        let blendB = existB * (1.0 - weight) + b * weight
                        dst[offset + 0] = UInt8(max(0, min(255, blendB * 255)))
                        dst[offset + 1] = UInt8(max(0, min(255, blendG * 255)))
                        dst[offset + 2] = UInt8(max(0, min(255, blendR * 255)))
                        dst[offset + 3] = 255
                    }
                }
            }
        }
    }
}
