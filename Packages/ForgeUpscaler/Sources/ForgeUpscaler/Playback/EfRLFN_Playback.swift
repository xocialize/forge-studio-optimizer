// EfRLFN_Playback.swift
//
// Role: Concrete `PlaybackTier` backed by the vendored EfRLFN MLX-Swift
//       port (Phase C.2 / Task #18). Wraps the existing `EfRLFN` module
//       with weight loading from the bundled safetensors and MLX-based
//       tile-driven inference.
//
// Plan ref: Forge-CodingPlan-v1.0.md §C.2 / §C.5
// ADR:      Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md
// Upstream: https://github.com/EvgeneyBogatyrev/EfRLFN (MIT)
// Weights:  Resources/efrlfn_x{2,4}.safetensors (Phase C.3 converter output)
//
// Tile shape: 128 / 16 — matches the export-tier `RealESRGAN_CoreML`
// numbers and the upstream EfRLFN inference tiling guidance. Plan §D.2's
// 1:8 ratio holds.
//
// Lazy init: the underlying `EfRLFN` MLX module is constructed eagerly at
// `init`, but the weights load on first use to keep the init path cheap
// when callers only want to query `name` / `inputResolution`. The first
// `upscale(_:)` triggers the safetensors load behind a `NSLock`.

import CoreVideo
import Foundation
import MLX
import MLXNN

/// EfRLFN playback tier — MLX-Swift, ~504K params, MIT.
///
/// Marked `@unchecked Sendable` because the MLX module + lock are mutated
/// across the `async` boundary; the lock guards the only crossing point.
public final class EfRLFN_Playback: PlaybackTier, @unchecked Sendable {

    // MARK: - PlaybackTier surface

    public let name: String
    public let scaleFactor: Int
    public let inputTileSize: Int = 128
    public let tileOverlap: Int = 16

    public var inputResolution: (width: Int, height: Int) {
        (inputTileSize, inputTileSize)
    }

    public var outputResolution: (width: Int, height: Int) {
        (inputTileSize * scaleFactor, inputTileSize * scaleFactor)
    }

    // MARK: - Internals

    private let model: EfRLFN
    private let tileProcessor: MLXTileProcessor
    private let weightsURL: URL
    private let loadLock = NSLock()
    private var weightsLoaded = false

    /// `mx.compile`-traced forward, built lazily once weights are loaded.
    /// Caching the compiled graph fuses the kernel and skips per-call graph
    /// construction; for video (constant frame/tile shape) the trace is
    /// reused across every frame after the first. Built under `loadLock`.
    private var compiledForward: (@Sendable (MLXArray) -> MLXArray)?

    /// Input-pixel ceiling for the whole-frame fast path. EfRLFN is fully
    /// convolutional (no internal downsampling), so frames at or below this
    /// run in a single forward pass; larger frames (e.g. the 4K corpus clip)
    /// fall back to 128-px tiling to bound peak memory. 1080p is the
    /// playback-tier design ceiling.
    ///
    /// DIAGNOSTIC ESCAPE HATCH: `FORGE_DISABLE_WHOLEFRAME=1` forces tiling
    /// (sets the budget to 0). Used to isolate the whole-frame path during the
    /// C.4 A/B regression triage (#35 was never runtime-tested headless).
    private var wholeFrameMaxPixels: Int {
        ProcessInfo.processInfo.environment["FORGE_DISABLE_WHOLEFRAME"] == "1"
            ? 0 : 1920 * 1080
    }

    /// DIAGNOSTIC ESCAPE HATCH: `FORGE_DISABLE_COMPILE=1` runs the model
    /// directly (no `mx.compile`), to isolate the compile path during triage.
    private var compileDisabled: Bool {
        ProcessInfo.processInfo.environment["FORGE_DISABLE_COMPILE"] == "1"
    }

    // MARK: - Init

    /// Initialise an EfRLFN playback tier.
    ///
    /// - Parameter scale: 4 only in this task. EfRLFN's published checkpoint
    ///   ships at x4; `efrlfn_x2.safetensors` is vendored for a future
    ///   `scale: 2` routing but isn't wired through here yet — Phase C.5b
    ///   work, tracked in the task brief's "Outstanding TODOs" section.
    public init(scale: Int = 4) throws {
        guard scale == 4 else {
            throw PlaybackTierError.unsupportedScale(scale)
        }
        self.scaleFactor = scale
        self.name = "efrlfn-x4"

        let resourceStem = "efrlfn_x4"
        guard let url = Bundle.module.url(
            forResource: resourceStem,
            withExtension: "safetensors"
        ) else {
            throw PlaybackTierError.weightsNotFound(resourceStem)
        }
        self.weightsURL = url
        self.model = EfRLFN(scale: scale)
        self.tileProcessor = MLXTileProcessor(
            tileSize: inputTileSize,
            overlap: tileOverlap,
            scale: scale
        )
    }

    // MARK: - PlaybackTier impl

    public func upscale(_ buffer: CVPixelBuffer) async throws -> CVPixelBuffer {
        let run = try ensureReady()
        let modelRef = model
        let noCompile = compileDisabled
        do {
            return try tileProcessor.processAdaptive(
                buffer,
                wholeFrameMaxPixels: wholeFrameMaxPixels
            ) { tile in
                let y = noCompile ? modelRef(tile) : run(tile)
                MLX.eval(y)
                return y
            }
        } catch let err as PlaybackTierError {
            throw err
        } catch {
            throw PlaybackTierError.inferenceError(String(describing: error))
        }
    }

    // MARK: - Weights + compile

    /// Load weights (once) and build the compiled forward (once), returning
    /// the cached compiled function. Both happen in the same critical section
    /// so the compile trace sees the post-load weights — weights are captured
    /// as constants (we never reload), which is the optimal inference form.
    private func ensureReady() throws -> @Sendable (MLXArray) -> MLXArray {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let f = compiledForward { return f }
        if !weightsLoaded {
            do {
                try model.loadWeights(from: weightsURL)
                weightsLoaded = true
            } catch let err as EfRLFNError {
                throw PlaybackTierError.modelLoadFailed(String(describing: err))
            } catch {
                throw PlaybackTierError.modelLoadFailed(String(describing: error))
            }
        }
        let m = model
        let f = compile { x in m(x) }
        compiledForward = f
        return f
    }
}
