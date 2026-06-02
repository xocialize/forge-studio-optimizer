import CoreMedia
import CoreVideo
import FormatBridge
import Foundation

/// Animated input (GIF/APNG) → MP4 (ADR-0022): looping pixel art belongs in a real
/// video codec, not a bloated GIF. Decodes every frame, runs the optional AI chain
/// per frame (alpha handled at the boundary, then flattened onto white — video is
/// opaque), and drives FormatBridge's VideoToolbox encoder with the source's per-frame
/// timing. ImageBridge already depends on FormatBridge for `FrameProcessor`, so this is
/// the sanctioned one-way handoff (ADR-0019) — the only place ImageBridge emits video.
public struct AnimatedToVideoConverter: Sendable {

    private let decoder: any StillDecoding

    init(decoder: any StillDecoding) { self.decoder = decoder }

    /// Returns the number of frames written. Throws `unsupportedFormat` if the source
    /// is a single still (use the still path instead).
    @discardableResult
    public func convert(input: URL, output: URL,
                        settings: VideoEncoderSettings = VideoEncoderSettings(codec: .hevc),
                        frameProcessor: (any FrameProcessor)? = nil) async throws -> Int {
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ImageBridgeError.fileNotFound(input.path)
        }
        let (frames, meta) = try decoder.decode(url: input)
        guard frames.count > 1 else {
            throw ImageBridgeError.unsupportedFormat("\(input.lastPathComponent) is not animated (1 frame)")
        }
        // Per-frame timing: GIF/APNG delays, else a 10 fps default for untimed sequences.
        let delays = meta.frameDelays ?? Array(repeating: 0.1, count: frames.count)

        // The still source has no video stream, so the encoder can't infer `.original`
        // dims — pin them explicitly to the (even-cropped) frame size, matching what
        // `flattenOntoWhiteEven` produces. HEVC/H.264 require even width/height.
        var videoSettings = settings
        videoSettings.resolution = .custom(width: meta.width & ~1, height: meta.height & ~1)

        let encoder = FormatBridgeFactory.makeEncoder()
        try encoder.configure(output: output, videoSettings: videoSettings, audioSettings: nil)  // video-only

        let timescale: CMTimeScale = 600
        var t = CMTime.zero
        for (i, frame) in frames.enumerated() {
            let processed = FrameRun.run(frame, processor: frameProcessor, alpha: meta.alpha)
            let opaque = Self.flattenOntoWhiteEven(processed)               // drop alpha + force even dims
            let secs = max(0.02, i < delays.count ? delays[i] : 0.1)        // clamp 0-delay → 50 fps cap
            let dur = CMTime(seconds: secs, preferredTimescale: timescale)
            try encoder.appendVideoFrame(opaque, at: t, duration: dur)
            t = CMTimeAdd(t, dur)
        }
        try await encoder.finish()
        return frames.count
    }

    // MARK: - frame prep

    /// Composite a premultiplied-BGRA buffer onto opaque white and crop to even
    /// dimensions (HEVC/H.264 require even width/height). Over white: out = premult +
    /// (255 − α) per channel (for α=255 this is a no-op). Returns an opaque BGRA buffer.
    static func flattenOntoWhiteEven(_ src: CVPixelBuffer) -> CVPixelBuffer {
        let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
        let w = sw & ~1, h = sh & ~1                                        // round down to even
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                == kCVReturnSuccess, let out = pb else { return src }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let sb = CVPixelBufferGetBaseAddress(src), let ob = CVPixelBufferGetBaseAddress(out) else { return src }
        let sStride = CVPixelBufferGetBytesPerRow(src), oStride = CVPixelBufferGetBytesPerRow(out)
        let sp = sb.assumingMemoryBound(to: UInt8.self), op = ob.assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< h {
            let sRow = y * sStride, oRow = y * oStride
            for x in 0 ..< w {
                let s = sRow + x * 4, o = oRow + x * 4
                let bg = 255 - Int(sp[s + 3])                               // white contribution
                op[o]     = UInt8(min(255, Int(sp[s]) + bg))
                op[o + 1] = UInt8(min(255, Int(sp[s + 1]) + bg))
                op[o + 2] = UInt8(min(255, Int(sp[s + 2]) + bg))
                op[o + 3] = 255
            }
        }
        return out
    }
}
