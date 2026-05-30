//
// BenchmarkMetrics.swift
// ForgeOptimizer / Benchmark
//
// Speed / quality / memory / compression / text metric Codable shapes
// from the schema document §4. Speed is intentionally a distribution
// (mean, median, p95, p99, stddev) rather than a scalar — per §1, video
// workloads' first-frame latency and thermal tails make single-number
// claims unreliable.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import Foundation

public struct SpeedMetrics: Codable, Sendable {
    public let msPerFrameMean: Double
    public let msPerFrameMedian: Double
    public let msPerFrameP95: Double
    public let msPerFrameP99: Double
    public let msPerFrameStddev: Double
    public let msFirstFrame: Double?
    public let realtimeFactor: Double
    public let fpsMean: Double?

    public init(
        msPerFrameMean: Double,
        msPerFrameMedian: Double,
        msPerFrameP95: Double,
        msPerFrameP99: Double,
        msPerFrameStddev: Double,
        msFirstFrame: Double? = nil,
        realtimeFactor: Double,
        fpsMean: Double? = nil
    ) {
        self.msPerFrameMean = msPerFrameMean
        self.msPerFrameMedian = msPerFrameMedian
        self.msPerFrameP95 = msPerFrameP95
        self.msPerFrameP99 = msPerFrameP99
        self.msPerFrameStddev = msPerFrameStddev
        self.msFirstFrame = msFirstFrame
        self.realtimeFactor = realtimeFactor
        self.fpsMean = fpsMean
    }

    enum CodingKeys: String, CodingKey {
        case msPerFrameMean = "ms_per_frame_mean"
        case msPerFrameMedian = "ms_per_frame_median"
        case msPerFrameP95 = "ms_per_frame_p95"
        case msPerFrameP99 = "ms_per_frame_p99"
        case msPerFrameStddev = "ms_per_frame_stddev"
        case msFirstFrame = "ms_first_frame"
        case realtimeFactor = "realtime_factor"
        case fpsMean = "fps_mean"
    }
}

public struct QualityMetrics: Codable, Sendable {
    public let vmaf: Double?
    public let vmafNeg: Double?
    public let psnrDB: Double?
    public let ssim: Double?
    public let msSSIM: Double?
    public let lpips: Double?
    public let siglip2IQA: Double?

    public init(
        vmaf: Double? = nil,
        vmafNeg: Double? = nil,
        psnrDB: Double? = nil,
        ssim: Double? = nil,
        msSSIM: Double? = nil,
        lpips: Double? = nil,
        siglip2IQA: Double? = nil
    ) {
        self.vmaf = vmaf
        self.vmafNeg = vmafNeg
        self.psnrDB = psnrDB
        self.ssim = ssim
        self.msSSIM = msSSIM
        self.lpips = lpips
        self.siglip2IQA = siglip2IQA
    }

    enum CodingKeys: String, CodingKey {
        case vmaf
        case vmafNeg = "vmaf_neg"
        case psnrDB = "psnr_db"
        case ssim
        case msSSIM = "ms_ssim"
        case lpips
        case siglip2IQA = "siglip2_iqa"
    }
}

public struct MemoryMetrics: Codable, Sendable {
    public let peakBytes: Int
    public let steadyStateBytes: Int?
    public let modelResidentBytes: Int?

    public init(
        peakBytes: Int,
        steadyStateBytes: Int? = nil,
        modelResidentBytes: Int? = nil
    ) {
        self.peakBytes = peakBytes
        self.steadyStateBytes = steadyStateBytes
        self.modelResidentBytes = modelResidentBytes
    }

    enum CodingKeys: String, CodingKey {
        case peakBytes = "peak_bytes"
        case steadyStateBytes = "steady_state_bytes"
        case modelResidentBytes = "model_resident_bytes"
    }
}

public struct CompressionMetrics: Codable, Sendable {
    public let inputBytes: Int
    public let outputBytes: Int
    public let ratioVsBaseline: Double?
    public let savingsVsBaseline: Double?
    public let encoder: String?
    public let encoderSettings: [String: AnyCodable]?

    public init(
        inputBytes: Int,
        outputBytes: Int,
        ratioVsBaseline: Double? = nil,
        savingsVsBaseline: Double? = nil,
        encoder: String? = nil,
        encoderSettings: [String: AnyCodable]? = nil
    ) {
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.ratioVsBaseline = ratioVsBaseline
        self.savingsVsBaseline = savingsVsBaseline
        self.encoder = encoder
        self.encoderSettings = encoderSettings
    }

    enum CodingKeys: String, CodingKey {
        case inputBytes = "input_bytes"
        case outputBytes = "output_bytes"
        case ratioVsBaseline = "ratio_vs_baseline"
        case savingsVsBaseline = "savings_vs_baseline"
        case encoder
        case encoderSettings = "encoder_settings"
    }
}

public struct TextMetrics: Codable, Sendable {
    public let ocrAccuracy: Double?
    public let ocrWordAccuracy: Double?
    public let edgeSharpness: Double?

    public init(
        ocrAccuracy: Double? = nil,
        ocrWordAccuracy: Double? = nil,
        edgeSharpness: Double? = nil
    ) {
        self.ocrAccuracy = ocrAccuracy
        self.ocrWordAccuracy = ocrWordAccuracy
        self.edgeSharpness = edgeSharpness
    }

    enum CodingKeys: String, CodingKey {
        case ocrAccuracy = "ocr_accuracy"
        case ocrWordAccuracy = "ocr_word_accuracy"
        case edgeSharpness = "edge_sharpness"
    }
}
