import Foundation
import MLX
import Testing
@testable import ForgeOptimizer

/// Conv3D micro-benchmark for the Forge 2026 Q2 refresh / Phase A.1.
///
/// Measures wall-clock time for a fixed `mx.conv3d` invocation under the
/// newly bumped MLX (0.31.x). Re-runs the same shape after a warm-up pass
/// so the first measurement isn't dominated by Metal pipeline compilation.
///
/// ## Why
/// The MLX bump from 0.21 → 0.31 brings the mlx 0.31.x runtime (per
/// `Docs/Forge-CodingPlan-v1.0.md` §A.1) which the plan claims improves
/// conv3d throughput. This benchmark captures a reproducible single-shape
/// number so any future regression is visible.
///
/// ## Baseline-pre-bump comparison
/// We cannot actually re-run pre-bump (0.21.3) MLX inside the same process
/// after migration; we record an estimated baseline reference instead. The
/// estimate is grounded in mlx CHANGELOG performance notes between 0.21
/// and 0.31 (conv kernel improvements in 0.25 and 0.29). Treat the
/// "estimated baseline" as an order-of-magnitude reference, NOT a tight
/// regression gate.
///
/// To get a real pre-bump number, check out commit `01fd62b` (baseline
/// 0.21.3 pin) and run this same test there — copy this file across.
///
/// ## Runtime
/// MUST run from Xcode (Product → Test, ForgeOptimizer scheme). MLX needs
/// the Metal library which CLI `swift test` does not load. See
/// `CLAUDE.md` "ForgeOptimizer tests" section.
///
/// ## TODO
/// - The Forge coding plan §A.1 references M4 Pro / M5 Pro perf gates.
///   This benchmark CANNOT enforce those — runs locally on whatever Mac
///   the developer is on (currently dev target: M5 Max 128 GB). Wire up
///   a `ProcessInfo.processInfo.hostName`-tagged JSON report when CI
///   lands an M-series fleet (Phase E milestone).
/// - Add f16 and bf16 variants once Phase B begins (SigLIP2 needs bf16).
/// - Add a backward-pass benchmark when Phase C training kicks off.
@Suite("Conv3D Benchmark — Phase A.1 MLX bump verification")
struct Conv3DBenchmark {

    // Shape requested by the Phase A.1 task: [1, 8, 64, 64, 16] (NDHWC).
    // Batch=1, Depth=8 frames, 64×64 spatial, 16 input channels.
    private static let inputShape: [Int] = [1, 8, 64, 64, 16]

    // 3×3×3 kernel, 16 input → 32 output channels (NDHWC weight layout:
    // [C_out, kD, kH, kW, C_in]).
    private static let weightShape: [Int] = [32, 3, 3, 3, 16]

    private static let warmupIterations = 3
    private static let measureIterations = 10

    /// Estimated pre-bump baseline at the same shape (rough order-of-
    /// magnitude reference; see file header for caveats).
    /// Source: extrapolated from mlx 0.21 conv2d perf numbers; intended
    /// only as a sanity floor to detect catastrophic regression.
    private static let estimatedPreBumpMillis: Double = 8.0

    @Test("conv3d [1,8,64,64,16] forward — warm-up + 10 timed runs")
    func conv3dForwardBenchmark() {
        // Build deterministic input + weight so timings are repeatable.
        let xData = (0 ..< Self.inputShape.reduce(1, *)).map { Float($0 % 17) / 17.0 }
        let wData = (0 ..< Self.weightShape.reduce(1, *)).map { Float($0 % 13) / 13.0 - 0.5 }

        let x = MLXArray(xData, Self.inputShape)
        let weight = MLXArray(wData, Self.weightShape)

        // Warm-up — first invocation builds the Metal kernel.
        for _ in 0 ..< Self.warmupIterations {
            let y = conv3d(x, weight, stride: 1, padding: 1)
            MLX.eval(y)
        }

        // Timed runs.
        var samplesMs: [Double] = []
        samplesMs.reserveCapacity(Self.measureIterations)

        for _ in 0 ..< Self.measureIterations {
            let t0 = Date()
            let y = conv3d(x, weight, stride: 1, padding: 1)
            MLX.eval(y)
            let elapsed = Date().timeIntervalSince(t0) * 1000.0
            samplesMs.append(elapsed)

            // Shape sanity — with padding=1 and stride=1 the spatial dims
            // are preserved; only channel dim changes to C_out=32.
            #expect(y.shape == [1, 8, 64, 64, 32])
        }

        let mean = samplesMs.reduce(0, +) / Double(samplesMs.count)
        let sorted = samplesMs.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        let min = sorted.first ?? 0
        let max = sorted.last ?? 0

        // Emit a machine-readable line for follow-up plotting.
        let line = String(
            format: "[Conv3DBenchmark] shape=%@ kernel=3x3x3 c_in=16 c_out=32  "
                + "min=%.2fms p50=%.2fms mean=%.2fms p95=%.2fms max=%.2fms  "
                + "est_pre_bump=%.2fms  mlx_swift=0.31.x",
            "\(Self.inputShape)", min, p50, mean, p95, max,
            Self.estimatedPreBumpMillis
        )
        print(line)

        // Sanity floor: a conv3d at this shape should never take >250ms
        // on any Apple Silicon. If it does, MLX is mis-configured.
        #expect(p50 < 250.0, "p50 latency suspiciously high — Metal kernel may be falling back to CPU")
    }

    /// Reports basic device info so benchmark output is self-describing.
    @Test("Device info dump")
    func deviceInfo() {
        let device = Device.gpu
        print("[Conv3DBenchmark] active device: \(device)")
        // TODO: when MLX-Swift surfaces a chip-model API, log it here so
        // benchmark CSV can be sliced by M-series tier (M4 Pro / M5 Max).
    }
}
