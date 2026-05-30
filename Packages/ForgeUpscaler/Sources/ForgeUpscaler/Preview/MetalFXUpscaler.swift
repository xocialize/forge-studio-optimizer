import CoreVideo
import Metal
import MetalFX

/// Fast upscaling for timeline scrubbing using MetalFX Spatial Scaler.
/// Based on AMD FSR — no ML model needed, runs in < 5ms at any resolution.
///
/// Use for:
/// - Timeline scrubbing / seeking preview
/// - Quick preview before committing to full SR export
/// - Fallback when Neural Engine is busy with other tiers
public final class MetalFXUpscaler: @unchecked Sendable {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let spatialScaler: MTLFXSpatialScaler

    private let inputWidth: Int
    private let inputHeight: Int
    private let outputWidth: Int
    private let outputHeight: Int

    /// Initialize MetalFX spatial upscaler.
    /// - Parameters:
    ///   - inputWidth: Source width (e.g., 960 for 1080p/2)
    ///   - inputHeight: Source height
    ///   - outputWidth: Target width (e.g., 3840 for 4K)
    ///   - outputHeight: Target height
    public init(
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw UpscalerError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw UpscalerError.commandQueueFailed
        }
        self.device = device
        self.commandQueue = queue
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual

        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            throw UpscalerError.scalerCreationFailed
        }
        self.spatialScaler = scaler
    }

    /// Upscale a CVPixelBuffer. Returns upscaled CVPixelBuffer.
    /// Typically completes in < 5ms for 1080p → 4K.
    public func upscale(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
        // Create input texture from CVPixelBuffer
        let inputTexture = try makeTexture(from: input, width: inputWidth, height: inputHeight)

        // Create output texture
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outputDescriptor.storageMode = .private

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw UpscalerError.textureCreationFailed
        }

        // Encode upscale
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw UpscalerError.commandBufferFailed
        }

        spatialScaler.colorTexture = inputTexture
        spatialScaler.outputTexture = outputTexture
        spatialScaler.encode(commandBuffer: commandBuffer)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read back to CVPixelBuffer
        return try readTexture(outputTexture, width: outputWidth, height: outputHeight)
    }

    /// Upscale directly between Metal textures (for pipeline integration).
    public func upscale(input: MTLTexture, output: MTLTexture, commandBuffer: MTLCommandBuffer) {
        spatialScaler.colorTexture = input
        spatialScaler.outputTexture = output
        spatialScaler.encode(commandBuffer: commandBuffer)
    }

    // MARK: - Texture ↔ CVPixelBuffer

    private func makeTexture(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> MTLTexture {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw UpscalerError.textureCreationFailed
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: baseAddress,
            bytesPerRow: bytesPerRow
        )

        return texture
    }

    private func readTexture(_ texture: MTLTexture, width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                          attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw UpscalerError.bufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let baseAddress = CVPixelBufferGetBaseAddress(buffer)!

        texture.getBytes(
            baseAddress,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        return buffer
    }
}
