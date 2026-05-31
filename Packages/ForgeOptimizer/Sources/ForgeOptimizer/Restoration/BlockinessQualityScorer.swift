import CoreVideo
import Foundation

/// Interim no-reference quality scorer based on **blocking-artifact energy** —
/// the dominant degradation in the low-bitrate H.264/HEVC/MPEG-2 signage this
/// product targets. License-clean (pure pixel math, no model), it ships today as
/// the IQA gate's signal until the SigLIP2 NR-IQA head (#23) is trained and
/// dropped into the same `NoReferenceQualityScoring` seam.
///
/// Idea: block-transform codecs quantize each NxN block independently, leaving
/// artificial intensity steps at the block grid. So compare the mean luma
/// gradient **across block boundaries** (multiples of `blockSize`) to the mean
/// gradient **inside** blocks. On clean content the two are equal (gradients are
/// content, not grid-aligned); on blocky content boundary gradients dominate.
///
///   blockiness = max(0, boundaryGrad − interiorGrad) / (interiorGrad + ε)
///   quality    = 1 − clamp(blockiness · sensitivity, 0, 1)
public struct BlockinessQualityScorer: NoReferenceQualityScoring {

    public var blockSize: Int
    /// Maps the blockiness ratio onto the `[0,1]` quality scale.
    public var sensitivity: Float
    /// Sub-sample stride (estimate, not exact) — keeps the per-frame gate cheap
    /// relative to NAFNet even at 4K.
    public var stride: Int

    public init(blockSize: Int = 8, sensitivity: Float = 6.0, stride: Int = 2) {
        self.blockSize = max(2, blockSize)
        self.sensitivity = sensitivity
        self.stride = max(1, stride)
    }

    public func quality(_ pb: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let planar = CVPixelBufferIsPlanar(pb)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0)
                                : CVPixelBufferGetBaseAddress(pb) else { return 1 }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let bpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        // NV12 plane 0 is 1-byte luma; packed BGRA is 4 bytes/px — sample the G
        // byte (offset 1), a fine luma proxy for a relative-gradient statistic.
        let pxStride = planar ? 1 : 4
        let lumaOff = planar ? 0 : 1
        guard w > blockSize, h > blockSize else { return 1 }

        @inline(__always) func luma(_ x: Int, _ y: Int) -> Int {
            Int(p[y * bpr + x * pxStride + lumaOff])
        }

        var bSum = 0.0, bN = 0.0, iSum = 0.0, iN = 0.0   // boundary / interior
        // `stride` sub-samples which lines we scan; WITHIN a line we step by 1 so
        // every block boundary (multiple of blockSize) is actually visited — a
        // stride that skips boundaries would see no blocking at all.
        // Horizontal gradients (vertical block edges at x % blockSize == 0).
        var y = 0
        while y < h {
            var x = 1
            while x < w {
                let d = abs(luma(x, y) - luma(x - 1, y))
                if x % blockSize == 0 { bSum += Double(d); bN += 1 } else { iSum += Double(d); iN += 1 }
                x += 1
            }
            y += stride
        }
        // Vertical gradients (horizontal block edges at y % blockSize == 0).
        var x = 0
        while x < w {
            var yy = 1
            while yy < h {
                let d = abs(luma(x, yy) - luma(x, yy - 1))
                if yy % blockSize == 0 { bSum += Double(d); bN += 1 } else { iSum += Double(d); iN += 1 }
                yy += 1
            }
            x += stride
        }
        guard bN > 0, iN > 0 else { return 1 }
        let boundary = bSum / bN
        let interior = iSum / iN
        let blockiness = max(0.0, boundary - interior) / (interior + 1.0)
        let quality = 1.0 - min(1.0, blockiness * Double(sensitivity))
        return Float(max(0.0, quality))
    }
}
