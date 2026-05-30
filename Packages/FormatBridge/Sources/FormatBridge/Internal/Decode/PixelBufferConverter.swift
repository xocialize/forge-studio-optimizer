import CoreVideo
import Foundation

/// Converts FFmpeg decoded frames (AVFrame) to CVPixelBuffer for VideoToolbox.
///
/// Handles the critical integration point between FFmpeg and Apple frameworks:
/// - 8-bit SDR: sws_scale from YUV420P → NV12 (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
/// - 10-bit HDR: sws_scale from YUV420P10LE → P010 (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
/// - Zero-copy path when source is already in a compatible pixel format
///
/// Uses CVPixelBufferPool for buffer reuse to minimize allocation churn.
final class PixelBufferConverter {
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    /// Creates or reuses a CVPixelBuffer from the pool.
    func createPixelBuffer(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            try createPool(width: width, height: height, pixelFormat: pixelFormat)
        }

        var pixelBuffer: CVPixelBuffer?
        guard let pool = pixelBufferPool else {
            throw FormatBridgeError.encoderConfigurationFailed("Failed to create pixel buffer pool")
        }

        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw FormatBridgeError.encoderConfigurationFailed("Failed to create pixel buffer from pool: \(status)")
        }

        return buffer
    }

    private func createPool(width: Int, height: Int, pixelFormat: OSType) throws {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let createdPool = pool else {
            throw FormatBridgeError.encoderConfigurationFailed("Failed to create pixel buffer pool: \(status)")
        }

        pixelBufferPool = createdPool
        poolWidth = width
        poolHeight = height
    }

    deinit {
        pixelBufferPool = nil
    }
}
