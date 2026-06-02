import CoreVideo
import Foundation

// Public still-image models (ImageBridge-PRD §3/§8). New to the still path;
// reuses FormatBridge enums (OptimizationLevel, QualityPreset, ColorSpaceInfo)
// where they apply rather than redefining.

/// Input still container formats ImageBridge can decode (via ImageIO).
public enum StillFormat: String, Sendable, CaseIterable {
    case png, jpeg, tiff, heic, bmp, gif
    case unknown
}

/// Output still formats (Phase 1 ship tier = native ImageIO; AVIF/WebP are a
/// later opt-in tier per ADR-0020).
public enum StillOutputFormat: String, Sendable, CaseIterable {
    case png, jpeg, tiff, heic
}

/// How alpha is carried. Stills routinely have alpha; the AI models are trained
/// on opaque RGB, so alpha must be unassociated before processing and recombined
/// after (Phase 3). Phase 1 preserves it through the round-trip.
public enum AlphaMode: String, Sendable {
    case none           // opaque
    case straight       // unassociated (un-premultiplied)
    case premultiplied  // associated
}

/// Sidecar metadata extracted at decode and (optionally) re-applied at encode.
public struct StillMetadata: Sendable {
    public let format: StillFormat
    public let width: Int
    public let height: Int
    public let bitDepth: Int            // bits per component (8 / 16)
    public let alpha: AlphaMode
    public let iccProfile: Data?        // embedded colour profile, preserved by default
    public let dpi: Double?             // pixels-per-inch, when present
    public let exifOrientation: Int     // 1…8 (TIFF/EXIF); 1 = up
    public let frameCount: Int          // >1 = animated/multi-page → sequence path (§7)

    public init(format: StillFormat, width: Int, height: Int, bitDepth: Int,
                alpha: AlphaMode, iccProfile: Data?, dpi: Double?,
                exifOrientation: Int, frameCount: Int) {
        self.format = format
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.alpha = alpha
        self.iccProfile = iccProfile
        self.dpi = dpi
        self.exifOrientation = exifOrientation
        self.frameCount = frameCount
    }
}

/// Encode parameters (still analog of `VideoEncoderSettings`).
public struct StillEncoderSettings: Sendable {
    public let format: StillOutputFormat
    /// Lossy quality in [0, 1] (JPEG/HEIC). Ignored for PNG/TIFF (lossless).
    public let quality: Double
    /// Drop ICC/EXIF/DPI on write (oxipng `--strip` analog). Default: preserve.
    public let stripMetadata: Bool

    public init(format: StillOutputFormat, quality: Double = 0.9, stripMetadata: Bool = false) {
        self.format = format
        self.quality = max(0, min(1, quality))
        self.stripMetadata = stripMetadata
    }
}
