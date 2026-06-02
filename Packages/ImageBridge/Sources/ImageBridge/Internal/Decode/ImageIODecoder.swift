import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes stills via ImageIO (`CGImageSource`) to BGRA `CVPixelBuffer`s, honoring
/// EXIF orientation and preserving ICC/alpha/DPI into `StillMetadata`. ImageIO
/// hands back packed RGB(A) — NOT NV12 — so the `ensureBGRA()` NV12 assumption from
/// the video path must never be applied here (PRD §4).
final class ImageIODecoderImpl: StillDecoding, @unchecked Sendable {

    /// Shared CIContext for CGImage↔CVPixelBuffer + orientation. Working space is
    /// pinned (sRGB) so we render deterministically; the source ICC is preserved
    /// in metadata and re-tagged on encode (PRD §9, the BT.709-pinning analog).
    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    func decode(url: URL) throws -> (frames: [CVPixelBuffer], metadata: StillMetadata) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageBridgeError.decodeFailed("CGImageSourceCreateWithURL(\(url.lastPathComponent))")
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw ImageBridgeError.decodeFailed("empty image source") }

        let meta = Self.metadata(from: src, url: url, frameCount: count)

        var frames: [CVPixelBuffer] = []
        frames.reserveCapacity(count)
        for i in 0 ..< count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else {
                throw ImageBridgeError.decodeFailed("decode frame \(i)")
            }
            // Honor EXIF orientation so downstream sees upright pixels.
            var ci = CIImage(cgImage: cg)
            if meta.exifOrientation != 1 {
                ci = ci.oriented(forExifOrientation: Int32(meta.exifOrientation))
            }
            frames.append(try Self.makeBuffer(from: ci, context: ciContext))
        }
        return (frames, meta)
    }

    // MARK: - Metadata

    static func metadata(from src: CGImageSource, url: URL, frameCount: Int) -> StillMetadata {
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let depth = (props[kCGImagePropertyDepth] as? Int) ?? 8
        let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1

        // DPI (explicit, else from JFIF/TIFF blocks).
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double)
            ?? ((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFXResolution] as? Double)

        // Embedded ICC profile, preserved by default.
        var icc: Data?
        if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
           let cs = cg.colorSpace, let data = cs.copyICCData() {
            icc = data as Data
        }

        let alpha: AlphaMode = {
            guard hasAlpha else { return .none }
            if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                switch cg.alphaInfo {
                case .premultipliedFirst, .premultipliedLast: return .premultiplied
                default: return .straight
                }
            }
            return .straight
        }()

        return StillMetadata(
            format: Self.format(from: src, url: url),
            width: w, height: h, bitDepth: depth, alpha: alpha,
            iccProfile: icc, dpi: dpi, exifOrientation: orientation, frameCount: frameCount
        )
    }

    static func format(from src: CGImageSource, url: URL) -> StillFormat {
        if let ut = CGImageSourceGetType(src) as String? {
            switch ut {
            case UTType.png.identifier: return .png
            case UTType.jpeg.identifier: return .jpeg
            case UTType.tiff.identifier: return .tiff
            case UTType.heic.identifier, "public.heif": return .heic
            case UTType.bmp.identifier: return .bmp
            case UTType.gif.identifier: return .gif
            default: break
            }
        }
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        case "heic", "heif": return .heic
        case "bmp": return .bmp
        case "gif": return .gif
        default: return .unknown
        }
    }

    // MARK: - CIImage → CVPixelBuffer (BGRA, IOSurface-backed)

    static func makeBuffer(from ci: CIImage, context: CIContext) throws -> CVPixelBuffer {
        let w = Int(ci.extent.width.rounded()), h = Int(ci.extent.height.rounded())
        guard w > 0, h > 0 else { throw ImageBridgeError.decodeFailed("zero-size image") }
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else {
            throw ImageBridgeError.decodeFailed("CVPixelBufferCreate \(w)x\(h)")
        }
        // Render at the image's origin (oriented images can have a non-zero extent).
        context.render(ci, to: buffer, bounds: CGRect(x: ci.extent.origin.x, y: ci.extent.origin.y,
                                                       width: CGFloat(w), height: CGFloat(h)),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buffer
    }
}

/// Probe = decode's metadata path without materialising pixels.
final class ImageIOProbeImpl: StillMediaProbing, @unchecked Sendable {
    func probe(url: URL) throws -> StillMetadata {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageBridgeError.decodeFailed("CGImageSourceCreateWithURL(\(url.lastPathComponent))")
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw ImageBridgeError.decodeFailed("empty image source") }
        return ImageIODecoderImpl.metadata(from: src, url: url, frameCount: count)
    }
}
