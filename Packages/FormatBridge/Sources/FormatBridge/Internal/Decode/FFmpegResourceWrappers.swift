import Foundation

// MARK: - FFmpeg RAII Wrappers
//
// Each FFmpeg C resource gets a Swift class wrapper that calls the appropriate
// av_*_free function in deinit. This guarantees cleanup on all code paths
// including cancellation and thrown errors.
//
// These wrappers will hold UnsafeMutablePointer<T> to FFmpeg C structs
// once FFmpegXC is available. For now they are placeholder types.

/// Wraps `AVFormatContext*` — calls `avformat_close_input` in deinit.
final class FormatContextWrapper {
    // TODO: var pointer: UnsafeMutablePointer<AVFormatContext>?
    deinit {
        // TODO: avformat_close_input(&pointer)
    }
}

/// Wraps `AVCodecContext*` — calls `avcodec_free_context` in deinit.
final class CodecContextWrapper {
    // TODO: var pointer: UnsafeMutablePointer<AVCodecContext>?
    deinit {
        // TODO: avcodec_free_context(&pointer)
    }
}

/// Wraps `AVFrame*` — calls `av_frame_free` in deinit.
final class FrameWrapper {
    // TODO: var pointer: UnsafeMutablePointer<AVFrame>?
    deinit {
        // TODO: av_frame_free(&pointer)
    }
}

/// Wraps `AVPacket*` — calls `av_packet_free` in deinit.
final class PacketWrapper {
    // TODO: var pointer: UnsafeMutablePointer<AVPacket>?
    deinit {
        // TODO: av_packet_free(&pointer)
    }
}

/// Wraps `SwsContext*` — calls `sws_freeContext` in deinit.
final class SwsContextWrapper {
    // TODO: var pointer: OpaquePointer?
    deinit {
        // TODO: sws_freeContext(pointer)
    }
}

/// Wraps `SwrContext*` — calls `swr_free` in deinit.
final class SwrContextWrapper {
    // TODO: var pointer: OpaquePointer?
    deinit {
        // TODO: swr_free(&pointer)
    }
}
