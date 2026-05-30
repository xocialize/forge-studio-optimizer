import MLX
import MLXNN

private let windowSizes: [Int: Int] = [2: 7, 3: 5, 4: 5, 5: 3, 6: 3]
private let nWeights: [Int: Int] = [2: 49, 3: 25, 4: 25, 5: 9, 6: 9]
private let featChannels: [Int: Int] = [2: 32, 3: 64, 4: 96]
private let mainInput: [Int: Int] = [2: 131, 3: 131, 4: 131, 5: 131, 6: 195]

/// Regularization module — feature-driven local convolution (f-lconv).
final class Regularization: Module {
    let level: Int
    let window: Int
    let numWeights: Int

    @ModuleInfo var feat: Sequential?
    @ModuleInfo var main: Sequential
    @ModuleInfo var dist: Sequential
    @ModuleInfo(key: "scale_x") var scaleX: Conv2d
    @ModuleInfo(key: "scale_y") var scaleY: Conv2d

    init(level: Int) {
        self.level = level
        self.window = windowSizes[level]!
        self.numWeights = nWeights[level]!

        let lr: Float = 0.1
        let mainIn = mainInput[level]!

        // Feature projection: only levels 2-4
        if let ch = featChannels[level] {
            self._feat.wrappedValue = Sequential {
                Conv2d(inputChannels: ch, outputChannels: 128, kernelSize: 1, stride: 1, padding: 0)
                LeakyReLU(negativeSlope: lr)
            }
        }

        // Main conv stack: 6 layers
        self._main.wrappedValue = Sequential {
            Conv2d(inputChannels: mainIn, outputChannels: 128, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 128, outputChannels: 128, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 128, outputChannels: 64, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 64, outputChannels: 64, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 64, outputChannels: 32, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
            Conv2d(inputChannels: 32, outputChannels: 32, kernelSize: 3, stride: 1, padding: 1)
            LeakyReLU(negativeSlope: lr)
        }

        // Distance weight prediction — capture values before closure to avoid self capture
        let nw = numWeights
        let w = window

        if level <= 4 {
            self._dist.wrappedValue = Sequential {
                Conv2d(inputChannels: 32, outputChannels: nw,
                       kernelSize: IntOrPair((w, 1)), stride: 1, padding: IntOrPair((w / 2, 0)))
                Conv2d(inputChannels: nw, outputChannels: nw,
                       kernelSize: IntOrPair((1, w)), stride: 1, padding: IntOrPair((0, w / 2)))
            }
        } else {
            self._dist.wrappedValue = Sequential {
                Conv2d(inputChannels: 32, outputChannels: nw, kernelSize: 3, stride: 1, padding: 1)
            }
        }

        self._scaleX.wrappedValue = Conv2d(inputChannels: nw, outputChannels: 1, kernelSize: 1, stride: 1, padding: 0)
        self._scaleY.wrappedValue = Conv2d(inputChannels: nw, outputChannels: 1, kernelSize: 1, stride: 1, padding: 0)
    }

    func callAsFunction(
        _ img1: MLXArray,
        _ img2: MLXArray,
        feat1: MLXArray,
        flow: MLXArray
    ) -> MLXArray {
        let img2Warped = GridSample.backwardWarp(img2, flow: flow)
        let brightnessDiff = MLX.mean(img1 - img2Warped, axis: -1, keepDims: true)

        let featProj: MLXArray
        if let proj = feat {
            featProj = proj(feat1)
        } else {
            featProj = feat1
        }

        let combined = MLX.concatenated([featProj, flow, brightnessDiff], axis: -1)
        let features = main(combined)

        var weights = dist(features)
        weights = softmax(weights, axis: -1)

        let flowMean = MLX.mean(flow, axes: [1, 2], keepDims: true)
        let flowCentered = flow - flowMean

        let flowX = flowCentered[0..., 0..., 0..., 0 ..< 1]
        let flowY = flowCentered[0..., 0..., 0..., 1 ..< 2]

        let patchesX = unfold(flowX)
        let patchesY = unfold(flowY)

        let weightedX = patchesX * weights
        let weightedY = patchesY * weights

        let outX = scaleX(weightedX)
        let outY = scaleY(weightedY)

        return MLX.concatenated([outX, outY], axis: -1) + flowMean
    }

    private func unfold(_ x: MLXArray) -> MLXArray {
        let shape = x.shape
        let H = shape[1]
        let W = shape[2]
        let pad = window / 2

        let xPadded = padded(x, widths: [IntOrPair((0, 0)), IntOrPair((pad, pad)), IntOrPair((pad, pad)), IntOrPair((0, 0))])

        var patches = [MLXArray]()
        for dy in 0 ..< window {
            for dx in 0 ..< window {
                patches.append(xPadded[0..., dy ..< (dy + H), dx ..< (dx + W), 0...])
            }
        }

        return MLX.concatenated(patches, axis: -1)
    }
}
