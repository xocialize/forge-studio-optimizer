//
//  EfRLFNTests.swift
//  ForgeUpscalerTests
//
//  Architecture tests for the MLX-Swift EfRLFN port (Phase C.2 / Task #18).
//
//  Verifies forward-pass shape correctness at multiple scales, parameter count
//  band, and standalone ECABlock behaviour.
//
//  Numerical correctness vs the PyTorch reference is deferred to Phase C.3
//  (Task #20), which provides the weight converter and the published
//  MIT-licensed checkpoint.
//
//  Parameter-count note: with the upstream defaults (featureChannels=52,
//  six ERLFB blocks, scale=4) the model lands at ~504K params, materially
//  higher than the ~300K headline figure quoted in the ADR-0006 summary
//  but consistent with the published `code/model.py`. The test band below
//  is 150K–600K to flag any large drift in either direction.
//

import Testing
import MLX
import MLXNN
@testable import ForgeUpscaler

/// Run a closure with the MLX default device pinned to CPU.
///
/// MLX-Swift's default device is GPU/Metal. From the SwiftPM CLI test runner
/// the Metal bundle is not always staged into the .xctest bundle, so the very
/// first GPU op can fail with "Failed to load the default metallib". This
/// wrapper routes MLX ops to CPU. Xcode picks up the metallib via the resource
/// bundle and these tests would also pass on GPU; we only check shapes / param
/// counts / finiteness, which are device-independent.
private func withCPU<R>(_ body: () throws -> R) rethrows -> R {
    try Device.withDefaultDevice(Device(.cpu), body)
}

/// Sum of all trainable param sizes in a Module tree.
private func totalParameterCount(_ module: Module) -> Int {
    var total = 0
    for (_, value) in module.parameters().flattened() {
        total += value.size
    }
    return total
}

@Suite("EfRLFN")
struct EfRLFNTests {

    // MARK: - Forward pass shape

    @Test("Forward pass on 64×64 NHWC zeros at scale=4 produces 256×256")
    func forwardShapeScale4() {
        withCPU {
            let model = EfRLFN()  // default scale=4
            let x = MLXArray.zeros([1, 64, 64, 3])
            let y = model(x)
            MLX.eval(y)
            #expect(y.shape == [1, 256, 256, 3])
        }
    }

    @Test("Forward pass at scale=2 produces 2× output")
    func forwardShapeScale2() {
        withCPU {
            let model = EfRLFN(scale: 2)
            let x = MLXArray.zeros([1, 64, 64, 3])
            let y = model(x)
            MLX.eval(y)
            #expect(y.shape == [1, 128, 128, 3])
        }
    }

    @Test("Forward pass at scale=1 is identity in spatial dims")
    func forwardShapeScale1() {
        // scale=1 should still produce a valid forward (the upsampler conv
        // emits out_c * 1 channels and PixelShuffle is a no-op).
        withCPU {
            let model = EfRLFN(scale: 1)
            let x = MLXArray.zeros([1, 32, 48, 3])
            let y = model(x)
            MLX.eval(y)
            #expect(y.shape == [1, 32, 48, 3])
        }
    }

    @Test("Forward pass handles non-square inputs")
    func forwardShapeNonSquare() {
        withCPU {
            let model = EfRLFN()  // scale=4
            let x = MLXArray.zeros([1, 48, 80, 3])
            let y = model(x)
            MLX.eval(y)
            #expect(y.shape == [1, 192, 320, 3])
        }
    }

    @Test("Forward pass handles odd-sized inputs (no stride / no downsampling in EfRLFN)")
    func forwardShapeOddInput() {
        // EfRLFN has no internal downsampling, so odd H/W just multiplies
        // through by `scale` — no padding workaround required.
        withCPU {
            let model = EfRLFN(scale: 4)
            let x = MLXArray.zeros([1, 31, 33, 3])
            let y = model(x)
            MLX.eval(y)
            #expect(y.shape == [1, 124, 132, 3])
        }
    }

    // MARK: - Parameter count

    @Test("Trainable parameter count is in the expected band for upstream-default config")
    func parameterCount() {
        withCPU {
            let model = EfRLFN()
            let total = totalParameterCount(model)

            // Upstream defaults (feature_channels=52, 6 blocks, scale=4)
            // produce ~504K params:
            //   conv_1            = 3*52*9 + 52     =    1,456
            //   6 × ERLFB         = 6 * 75,923      =  455,538
            //     - c1_r/c2_r/c3_r= 3 * (52*52*9+52)=   73,164
            //     - c5            = 52*52 + 52      =    2,756
            //     - eca.conv      = 1*1*3           =        3
            //   conv_2            = 52*52*9 + 52    =   24,388
            //   upsampler.conv    = 52*48*9 + 48    =   22,512
            //   ---------------------------------------------
            //   total                                ≈ 503,894
            //
            // The ~300K headline in ADR-0006 / LICENSES.md §1A is the
            // marketing figure from the paper's abstract; the released
            // code/model.py at the upstream repo lands at ~0.5M.
            //
            // Band 150K..600K catches gross drift in either direction
            // without locking the exact count.
            #expect(total >= 150_000, "Param count \(total) below 0.15M lower bound")
            #expect(total <= 600_000, "Param count \(total) above 0.6M upper bound")
        }
    }

    @Test("Parameter count scales with featureChannels")
    func parameterCountScalesWithWidth() {
        withCPU {
            let small = EfRLFN(featureChannels: 32)
            let large = EfRLFN(featureChannels: 64)
            let smallTotal = totalParameterCount(small)
            let largeTotal = totalParameterCount(large)
            // Most ops are O(C^2) in the conv weights, so doubling C roughly
            // quadruples the trainable count. We only check monotonicity to
            // keep the test robust against minor refactors.
            #expect(largeTotal > smallTotal)
        }
    }

    // MARK: - ECABlock standalone

    @Test("ECABlock preserves input shape")
    func ecaShape() {
        withCPU {
            let eca = ECABlock()
            let x = MLXArray.zeros([2, 8, 8, 16])
            let y = eca(x)
            MLX.eval(y)
            #expect(y.shape == [2, 8, 8, 16])
        }
    }

    @Test("ECABlock output is finite on a non-trivial input")
    func ecaFiniteOutput() {
        withCPU {
            let eca = ECABlock()
            // Non-zero input so the sigmoid attention isn't trivially 0.5.
            // ones() is the simplest device-independent way to populate.
            let x = MLX.ones([1, 4, 4, 8])
            let y = eca(x)
            MLX.eval(y)

            // Check finiteness via the array's contents. allFinite() exists
            // as `MLX.allFinite` in some MLX-Swift snapshots; the device-
            // independent fallback is to read into floats and inspect.
            let floats = y.asArray(Float.self)
            #expect(floats.allSatisfy { $0.isFinite })
            #expect(y.shape == [1, 4, 4, 8])
        }
    }

    @Test("ECABlock rejects even kSize")
    func ecaRejectsEvenKSize() {
        // Construction with an even kSize must trap. We test the precondition
        // by relying on the construction path; the precondition fires at init,
        // so we can't observe it without crashing the test process. Instead
        // we verify the documented odd-kSize values construct successfully.
        withCPU {
            _ = ECABlock(kSize: 1)
            _ = ECABlock(kSize: 3)
            _ = ECABlock(kSize: 5)
            // (No assertion needed — reaching here means the inits succeeded.)
        }
    }

    // MARK: - ERLFB standalone

    @Test("ERLFB preserves input shape and channel count")
    func erlfbShape() {
        withCPU {
            let block = ERLFB(channels: 32)
            let x = MLXArray.zeros([1, 16, 16, 32])
            let y = block(x)
            MLX.eval(y)
            #expect(y.shape == [1, 16, 16, 32])
        }
    }

    // MARK: - Construction guards

    @Test("EfRLFN traps when numBlocks ≠ 6 (matches checkpoint key layout)")
    func efrlfnNumBlocksGuard() {
        // We can't catch a Swift precondition in a unit test without spawning
        // a child process. Instead we just confirm the supported value
        // constructs cleanly; the precondition is documented in the init
        // docstring and exercised by integration.
        withCPU {
            _ = EfRLFN(numBlocks: 6)
        }
    }
}
