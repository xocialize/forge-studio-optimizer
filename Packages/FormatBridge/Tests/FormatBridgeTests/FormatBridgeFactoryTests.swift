import Testing

@testable import FormatBridge

@Suite("FormatBridgeFactory")
struct FormatBridgeFactoryTests {

    @Test("Initialize does not crash")
    func initialize() {
        FormatBridgeFactory.initialize(logLevel: .warning)
    }

    @Test("makeProbe returns a MediaProbing instance")
    func makeProbe() {
        let probe = FormatBridgeFactory.makeProbe()
        #expect(probe is FFmpegFormatProbe)
    }

    @Test("makeDecoder returns a VideoDecoding instance")
    func makeDecoder() {
        let decoder = FormatBridgeFactory.makeDecoder()
        #expect(decoder is FFmpegDecoderImpl)
    }

    @Test("makeEncoder returns a VideoEncoding instance")
    func makeEncoder() {
        let encoder = FormatBridgeFactory.makeEncoder()
        #expect(encoder is NativeEncoderImpl)
    }

    @Test("makeOrchestrator returns a ConversionOrchestrating instance")
    func makeOrchestrator() {
        let orchestrator = FormatBridgeFactory.makeOrchestrator()
        #expect(orchestrator is ConversionOrchestrator)
    }

    @Test("makeOrchestrator accepts a FrameProcessor")
    func makeOrchestratorWithProcessor() {
        let processor = ModelChain([])
        let orchestrator = FormatBridgeFactory.makeOrchestrator(frameProcessor: processor)
        #expect(orchestrator is ConversionOrchestrator)
    }
}
