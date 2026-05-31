import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Constant-quality VideoToolbox encoder (ADR-0013 ship encoder).
///
/// Encodes via `VTCompressionSession` using `kVTCompressionPropertyKey_Quality`
/// — the constant-quality ("CRF-equivalent") knob `AVAssetWriter` does NOT expose
/// for HEVC/H.264 — and muxes the encoded samples to MP4 via an `AVAssetWriter`
/// **passthrough** input. HEVC default / H.264 fallback; hardware-accelerated on
/// the Apple-silicon media engine. The quality value is what the VMAF-targeted
/// search drives (Step 1, ADR-0014).
///
/// Video-only (the NAFNet/optimize path carries no audio). B-frames on, ~2 s GOP
/// (HLS-friendly, matching the Vimeo fingerprint we reverse-engineered).
final class VideoToolboxEncoderImpl: VideoEncoding, @unchecked Sendable {

    private var session: VTCompressionSession?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var appendError: Error?
    private(set) var isHardwareAccelerated = false

    func configure(output: URL,
                   videoSettings: VideoEncoderSettings,
                   audioSettings: AudioEncoderSettings?) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let w = videoSettings.outputWidth
        let h = videoSettings.outputHeight
        guard w > 0, h > 0 else { throw EncoderError.configure("bad output size \(w)x\(h)") }

        // The passthrough writer input is created lazily on the FIRST encoded
        // sample — a passthrough AVAssetWriterInput needs a sourceFormatHint
        // (the CMVideoFormatDescription), which only exists once VT has encoded
        // a frame. See appendEncoded(_:).
        self.writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        // VTCompressionSession (block-based output → create with no callback).
        let codecType: CMVideoCodecType =
            videoSettings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(w), height: Int32(h),
            codecType: codecType,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let session = created else {
            throw EncoderError.configure("VTCompressionSessionCreate failed (\(status))")
        }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        let quality = videoSettings.constantQuality ?? Self.presetQuality(videoSettings.quality)
        set(kVTCompressionPropertyKey_Quality, NSNumber(value: max(0, min(1, quality))))
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue)        // B-frames
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: videoSettings.outputFrameRate))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2.0)) // ~2 s GOP
        set(kVTCompressionPropertyKey_ProfileLevel,
            videoSettings.codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel
                                         : kVTProfileLevel_H264_High_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(session)

        // HEVC/H.264 encode runs on the Apple-silicon media engine.
        isHardwareAccelerated = true
    }

    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime, duration: CMTime) throws {
        if let e = current(&appendError) { throw e }
        guard let session = session else { throw EncoderError.configure("not configured") }
        // Frame reordering means the output handler fires asynchronously (often
        // during finish()/CompleteFrames). It appends the encoded sample.
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: time,
            duration: duration, frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sb = sampleBuffer else {
                self.record(EncoderError.encode("VT encode status \(status)")); return
            }
            self.appendEncoded(sb)
        }
        if status != noErr { throw EncoderError.encode("EncodeFrame failed (\(status))") }
    }

    private func appendEncoded(_ sb: CMSampleBuffer) {
        lock.lock()
        if videoInput == nil {
            // First encoded sample — set up the passthrough input from its
            // format description, then start the writer + session.
            guard let writer = writer,
                  let fmt = CMSampleBufferGetFormatDescription(sb) else {
                if appendError == nil { appendError = EncoderError.encode("no format on encoded sample") }
                lock.unlock(); return
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                if appendError == nil { appendError = EncoderError.encode("writer rejected passthrough input") }
                lock.unlock(); return
            }
            writer.add(input)
            guard writer.startWriting() else {
                if appendError == nil {
                    appendError = EncoderError.encode("startWriting failed: \(writer.error?.localizedDescription ?? "?")")
                }
                lock.unlock(); return
            }
            writer.startSession(atSourceTime: .zero)
            videoInput = input
        }
        let input = videoInput!
        lock.unlock()

        while !input.isReadyForMoreMediaData {           // offline — a short spin is fine
            if writer?.status == .failed { return }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if !input.append(sb) {
            record(writer?.error ?? EncoderError.encode("append failed"))
        }
    }

    func appendAudioSamples(_ sampleBuffer: CMSampleBuffer) throws {
        throw EncoderError.encode("video-only encoder — no audio input configured")
    }

    func finish() async throws {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        if let e = current(&appendError) { throw e }
        guard let input = videoInput else { throw EncoderError.encode("no frames encoded") }
        input.markAsFinished()
        guard let writer = writer else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        if writer.status != .completed {
            throw EncoderError.encode("writer status \(writer.status.rawValue): "
                + (writer.error?.localizedDescription ?? "?"))
        }
    }

    // MARK: - Helpers

    private func record(_ e: Error) { lock.lock(); if appendError == nil { appendError = e }; lock.unlock() }
    private func current(_ e: inout Error?) -> Error? { lock.lock(); defer { lock.unlock() }; return e }

    /// QualityPreset → VideoToolbox quality [0,1] (used when no explicit
    /// `constantQuality` is set). Coarser than x264 CRF by design (ADR-0013).
    static func presetQuality(_ p: QualityPreset) -> Float {
        switch p {
        case .low: return 0.40
        case .medium: return 0.55
        case .high: return 0.70
        case .maximum: return 0.85
        }
    }

    enum EncoderError: Error, CustomStringConvertible {
        case configure(String), encode(String)
        var description: String {
            switch self {
            case .configure(let s): return "VideoToolboxEncoder configure: \(s)"
            case .encode(let s):    return "VideoToolboxEncoder: \(s)"
            }
        }
    }
}
