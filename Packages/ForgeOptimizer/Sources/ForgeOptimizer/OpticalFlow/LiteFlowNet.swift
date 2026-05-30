import MLX
import MLXNN

/// Full LiteFlowNet optical flow model — coarse-to-fine estimation (levels 6→2).
final class LiteFlowNet: Module {
    @ModuleInfo var features: Features

    @ModuleInfo(key: "matching_2") var matching2: Matching
    @ModuleInfo(key: "matching_3") var matching3: Matching
    @ModuleInfo(key: "matching_4") var matching4: Matching
    @ModuleInfo(key: "matching_5") var matching5: Matching
    @ModuleInfo(key: "matching_6") var matching6: Matching

    @ModuleInfo(key: "subpixel_2") var subpixel2: Subpixel
    @ModuleInfo(key: "subpixel_3") var subpixel3: Subpixel
    @ModuleInfo(key: "subpixel_4") var subpixel4: Subpixel
    @ModuleInfo(key: "subpixel_5") var subpixel5: Subpixel
    @ModuleInfo(key: "subpixel_6") var subpixel6: Subpixel

    @ModuleInfo(key: "regularization_2") var reg2: Regularization
    @ModuleInfo(key: "regularization_3") var reg3: Regularization
    @ModuleInfo(key: "regularization_4") var reg4: Regularization
    @ModuleInfo(key: "regularization_5") var reg5: Regularization
    @ModuleInfo(key: "regularization_6") var reg6: Regularization

    override init() {
        self._features.wrappedValue = Features()

        self._matching2.wrappedValue = Matching(level: 2)
        self._matching3.wrappedValue = Matching(level: 3)
        self._matching4.wrappedValue = Matching(level: 4)
        self._matching5.wrappedValue = Matching(level: 5)
        self._matching6.wrappedValue = Matching(level: 6)

        self._subpixel2.wrappedValue = Subpixel(level: 2)
        self._subpixel3.wrappedValue = Subpixel(level: 3)
        self._subpixel4.wrappedValue = Subpixel(level: 4)
        self._subpixel5.wrappedValue = Subpixel(level: 5)
        self._subpixel6.wrappedValue = Subpixel(level: 6)

        self._reg2.wrappedValue = Regularization(level: 2)
        self._reg3.wrappedValue = Regularization(level: 3)
        self._reg4.wrappedValue = Regularization(level: 4)
        self._reg5.wrappedValue = Regularization(level: 5)
        self._reg6.wrappedValue = Regularization(level: 6)
    }

    /// Run optical flow estimation.
    /// - Parameters:
    ///   - img1: [B, H, W, 3] preprocessed first frame (BGR, mean-subtracted, padded to 32×)
    ///   - img2: [B, H, W, 3] preprocessed second frame
    /// - Returns: [B, H/2, W/2, 2] optical flow scaled by 20.0
    func callAsFunction(_ img1: MLXArray, _ img2: MLXArray) -> MLXArray {
        let feats1 = features(img1)
        let feats2 = features(img2)

        let imgs1 = buildImagePyramid(img1)
        let imgs2 = buildImagePyramid(img2)

        let modules: [(Matching, Subpixel, Regularization)] = [
            (matching6, subpixel6, reg6),
            (matching5, subpixel5, reg5),
            (matching4, subpixel4, reg4),
            (matching3, subpixel3, reg3),
            (matching2, subpixel2, reg2),
        ]
        let levels = [6, 5, 4, 3, 2]

        var flow: MLXArray? = nil
        var corr: MLXArray? = nil

        for (i, level) in levels.enumerated() {
            let (matching, subpixel, reg) = modules[i]

            let result = matching(feats1[level]!, feats2[level]!,
                                  flowPrev: flow, corrPrev: corr)
            flow = result.flow
            corr = result.corr

            flow = subpixel(feats1[level]!, feats2[level]!, flow: flow!)
            flow = reg(imgs1[level]!, imgs2[level]!, feat1: feats1[level]!, flow: flow!)
        }

        return flow! * 20.0
    }

    private func buildImagePyramid(_ img: MLXArray) -> [Int: MLXArray] {
        var pyramid: [Int: MLXArray] = [1: img]
        var current = img

        for level in 2 ... 6 {
            let shape = current.shape
            let H = shape[1]
            let W = shape[2]

            // Pad to even if needed
            var c = current
            if H % 2 != 0 || W % 2 != 0 {
                c = padded(c, widths: [IntOrPair((0, 0)), IntOrPair((0, H % 2)), IntOrPair((0, W % 2)), IntOrPair((0, 0))])
            }

            let newShape = c.shape
            let newH = newShape[1] / 2
            let newW = newShape[2] / 2
            let C = newShape[3]

            current = c.reshaped([newShape[0], newH, 2, newW, 2, C]).mean(axes: [2, 4])
            pyramid[level] = current
        }

        return pyramid
    }
}
