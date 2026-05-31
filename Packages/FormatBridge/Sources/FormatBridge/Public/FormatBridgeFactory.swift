import Foundation

/// Sole public entry point for FormatBridge.
///
/// All concrete implementations are internal — consumers interact only through protocols.
/// This keeps FFmpeg C API details completely hidden from downstream apps.
///
/// ## Usage
/// ```swift
/// import FormatBridge
///
/// FormatBridgeFactory.initialize()
/// let probe = FormatBridgeFactory.makeProbe()
/// let info = try await probe.probe(url: inputURL)
///
/// let orchestrator = FormatBridgeFactory.makeOrchestrator()
/// try await orchestrator.convert(input: inputURL, output: outputURL, settings: .fast) { progress in
///     print("\(progress.stage.rawValue): \(Int(progress.percentage * 100))%")
/// }
/// ```
public enum FormatBridgeFactory {

    /// Initialize FormatBridge. Call once at app launch.
    /// Configures FFmpeg logging level and performs any one-time setup.
    public static func initialize(logLevel: LogLevel = .warning) {
        FFmpegLogger.configure(level: logLevel)
    }

    /// Creates a media probe for inspecting input files.
    public static func makeProbe() -> any MediaProbing {
        FFmpegFormatProbe()
    }

    /// Creates a video decoder (FFmpeg-backed).
    public static func makeDecoder() -> any VideoDecoding {
        FFmpegDecoderImpl()
    }

    /// Creates a native encoder (VideoToolbox + AVAssetWriter).
    public static func makeEncoder() -> any VideoEncoding {
        NativeEncoderImpl()
    }

    /// Creates the constant-quality VideoToolbox encoder (ADR-0013 ship encoder)
    /// — `VTCompressionSession` with the `kVTCompressionPropertyKey_Quality` knob
    /// the VMAF-targeted search drives, muxed via AVAssetWriter passthrough.
    /// Video-only. Set `VideoEncoderSettings.constantQuality` for an explicit
    /// quality target.
    public static func makeQualityEncoder() -> any VideoEncoding {
        VideoToolboxEncoderImpl()
    }

    /// Creates a conversion orchestrator that manages the full pipeline.
    ///
    /// - Parameter frameProcessor: Optional AI frame processor (e.g., ForgeOptimizer's `ModelChain`).
    ///   Pass `nil` for direct conversion without optimization.
    public static func makeOrchestrator(frameProcessor: (any FrameProcessor)? = nil) -> any ConversionOrchestrating {
        ConversionOrchestrator(
            probe: makeProbe(),
            frameProcessor: frameProcessor
        )
    }
}
