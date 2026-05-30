import MLX
import MLXNN

private let backwardScales: [Int: Float] = [2: 10.0, 3: 5.0, 4: 2.5, 5: 1.25, 6: 0.625]
private let finalKernel: [Int: Int] = [2: 7, 3: 5, 4: 5, 5: 3, 6: 3]

/// Grouped transposed convolution — stores [groups, kH, kW, 1] weight and applies per-channel.
/// Uses ConvTranspose2d with groups support (MLX-Swift 0.21+ supports groups in Conv2d).
final class GroupedConvTranspose: Module {
    @ModuleInfo var weight: MLXArray

    let groups: Int

    init(groups: Int, kernelSize: Int = 4) {
        self.groups = groups
        self._weight.wrappedValue = MLXArray.zeros([groups, kernelSize, kernelSize, 1])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: [B, H, W, groups]
        // Perform per-channel 2x upsample via transposed conv
        // Split channels, apply each, concatenate
        var results = [MLXArray]()
        for g in 0 ..< groups {
            let xg = x[0..., 0..., 0..., g ..< (g + 1)]  // [B, H, W, 1]
            let wg = weight[g ..< (g + 1)]  // [1, kH, kW, 1]
            let out = convTransposed2d(xg, wg, stride: [2, 2], padding: [1, 1])
            results.append(out)
        }
        return concatenated(results, axis: -1)
    }
}

/// Matching module for a single pyramid level.
final class Matching: Module {
    let level: Int
    let scale: Float

    @ModuleInfo var feat: Sequential?
    @ModuleInfo var main: Sequential
    @ModuleInfo var upflow: GroupedConvTranspose?
    @ModuleInfo var upcorr: GroupedConvTranspose?

    init(level: Int) {
        self.level = level
        self.scale = backwardScales[level]!

        let lr: Float = 0.1
        let k = finalKernel[level]!
        let p = k / 2

        if level == 2 {
            self._feat.wrappedValue = Sequential {
                Conv2d(inputChannels: 32, outputChannels: 64, kernelSize: 1, stride: 1, padding: 0)
                LeakyReLU(negativeSlope: lr)
            }
        }

        self._main.wrappedValue = Sequential {
            Conv2d(inputChannels: 49, outputChannels: 128, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 128, outputChannels: 64, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 64, outputChannels: 32, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 32, outputChannels: 2, kernelSize: IntOrPair(k), stride: 1, padding: IntOrPair(p))
        }

        if level < 6 {
            self._upflow.wrappedValue = GroupedConvTranspose(groups: 2)
        }
        if level <= 3 {
            self._upcorr.wrappedValue = GroupedConvTranspose(groups: 49)
        }
    }

    func callAsFunction(
        _ feat1: MLXArray,
        _ feat2: MLXArray,
        flowPrev: MLXArray?,
        corrPrev: MLXArray?
    ) -> (flow: MLXArray, corr: MLXArray) {
        var f1 = feat1
        var f2 = feat2

        if let featProj = feat {
            f1 = featProj(f1)
            f2 = featProj(f2)
        }

        let flowUp: MLXArray
        let f2Warped: MLXArray

        if let prev = flowPrev, let up = upflow {
            flowUp = up(prev) * scale
            f2Warped = GridSample.backwardWarp(f2, flow: flowUp)
        } else {
            let shape = f1.shape
            flowUp = MLXArray.zeros([shape[0], shape[1], shape[2], 2])
            f2Warped = f2
        }

        var corr = Correlation.correlate(f1, f2Warped)

        if let prev = corrPrev, let up = upcorr {
            corr = corr + up(prev)
        }

        let flowDelta = main(corr)
        let flow = flowUp + flowDelta

        return (flow, corr)
    }
}
