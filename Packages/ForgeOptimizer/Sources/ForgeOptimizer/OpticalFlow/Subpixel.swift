import MLX
import MLXNN

private let inputChannels: [Int: Int] = [2: 130, 3: 130, 4: 194, 5: 258, 6: 386]
private let finalKernels: [Int: Int] = [2: 7, 3: 5, 4: 5, 5: 3, 6: 3]

/// Sub-pixel flow refinement module.
final class Subpixel: Module {
    let level: Int

    @ModuleInfo var feat: Sequential?
    @ModuleInfo var main: Sequential

    init(level: Int) {
        self.level = level
        let lr: Float = 0.1
        let inCh = inputChannels[level]!
        let k = finalKernels[level]!
        let p = k / 2

        if level == 2 {
            self._feat.wrappedValue = Sequential {
                Conv2d(inputChannels: 32, outputChannels: 64, kernelSize: 1, stride: 1, padding: 0)
                LeakyReLU(negativeSlope: lr)
            }
        }

        self._main.wrappedValue = Sequential {
            Conv2d(inputChannels: inCh, outputChannels: 128, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 128, outputChannels: 64, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 64, outputChannels: 32, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 32, outputChannels: 2, kernelSize: IntOrPair(k), stride: 1, padding: IntOrPair(p))
        }
    }

    func callAsFunction(_ feat1: MLXArray, _ feat2: MLXArray, flow: MLXArray) -> MLXArray {
        var f1 = feat1
        var f2 = feat2

        if let proj = feat {
            f1 = proj(f1)
            f2 = proj(f2)
        }

        let f2Warped = GridSample.backwardWarp(f2, flow: flow)
        let combined = MLX.concatenated([f1, f2Warped, flow], axis: -1)
        let delta = main(combined)
        return flow + delta
    }
}
