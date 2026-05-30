import MLX
import MLXNN

/// 6-level feature pyramid encoder (NetC).
/// Shared between both frames. Outputs multi-scale features at 1x through 1/32x resolution.
final class Features: Module {
    @ModuleInfo var one: Sequential
    @ModuleInfo var two: Sequential
    @ModuleInfo var thr: Sequential
    @ModuleInfo var fou: Sequential
    @ModuleInfo var fiv: Sequential
    @ModuleInfo var six: Sequential

    override init() {
        let lr: Float = 0.1
        self._one.wrappedValue = Sequential {
            Conv2d(inputChannels: 3, outputChannels: 32, kernelSize: 7, stride: 1, padding: 3)
            LeakyReLU(negativeSlope: lr)
        }
        self._two.wrappedValue = Sequential {
            Conv2d(inputChannels: 32, outputChannels: 32, kernelSize: 3, stride: 2, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 32, outputChannels: 32, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 32, outputChannels: 32, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
        }
        self._thr.wrappedValue = Sequential {
            Conv2d(inputChannels: 32, outputChannels: 64, kernelSize: 3, stride: 2, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 64, outputChannels: 64, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
        }
        self._fou.wrappedValue = Sequential {
            Conv2d(inputChannels: 64, outputChannels: 96, kernelSize: 3, stride: 2, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 96, outputChannels: 96, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
        }
        self._fiv.wrappedValue = Sequential {
            Conv2d(inputChannels: 96, outputChannels: 128, kernelSize: 3, stride: 2, padding: 1)
            LeakyReLU(negativeSlope: lr)
        }
        self._six.wrappedValue = Sequential {
            Conv2d(inputChannels: 128, outputChannels: 192, kernelSize: 3, stride: 2, padding: 1)
            LeakyReLU(negativeSlope: lr)
        }
    }

    func callAsFunction(_ x: MLXArray) -> [Int: MLXArray] {
        let f1 = one(x)
        let f2 = two(f1)
        let f3 = thr(f2)
        let f4 = fou(f3)
        let f5 = fiv(f4)
        let f6 = six(f5)
        return [1: f1, 2: f2, 3: f3, 4: f4, 5: f5, 6: f6]
    }
}
