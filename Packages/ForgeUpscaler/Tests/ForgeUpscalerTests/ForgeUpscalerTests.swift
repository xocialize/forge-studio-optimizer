import Testing
@testable import ForgeUpscaler

@Suite("ForgeUpscaler")
struct ForgeUpscalerTests {

    @Test("TemporalBlender initializes with correct alpha")
    func temporalBlenderInit() {
        let blender = TemporalBlender(alpha: 0.4, sceneChangeThreshold: 0.15)
        #expect(blender.alpha == 0.4)
    }

    @Test("TileProcessor has correct scale factor")
    func tileProcessorScale() {
        let tp = TileProcessor(tileSize: 128, overlap: 16, scale: 4)
        #expect(tp.scale == 4)
    }
}