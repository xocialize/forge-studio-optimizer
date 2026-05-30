import Testing
import MLX
import MLXNN
@testable import ForgeOptimizer

@Suite("LiteFlowNet")
struct LiteFlowNetTests {

    @Test("Feature pyramid produces correct shapes")
    func featureShapes() {
        let features = Features()
        let x = MLXArray.zeros([1, 256, 256, 3])
        let feats = features(x)

        #expect(feats[1]!.shape == [1, 256, 256, 32])
        #expect(feats[2]!.shape == [1, 128, 128, 32])
        #expect(feats[3]!.shape == [1, 64, 64, 64])
        #expect(feats[4]!.shape == [1, 32, 32, 96])
        #expect(feats[5]!.shape == [1, 16, 16, 128])
        #expect(feats[6]!.shape == [1, 8, 8, 192])
    }

    @Test("Correlation produces 49-channel output")
    func correlationShape() {
        let feat1 = MLXArray.zeros([1, 16, 16, 64])
        let feat2 = MLXArray.zeros([1, 16, 16, 64])
        let corr = Correlation.correlate(feat1, feat2)
        MLX.eval(corr)

        #expect(corr.shape == [1, 16, 16, 49])
    }

    @Test("Full model forward pass produces correct output shape")
    func forwardShape() {
        let model = LiteFlowNet()
        let img1 = MLXArray.zeros([1, 256, 256, 3])
        let img2 = MLXArray.zeros([1, 256, 256, 3])

        let flow = model(img1, img2)
        MLX.eval(flow)

        // Output at level 2: 256/2 = 128
        #expect(flow.shape == [1, 128, 128, 2])
    }
}
