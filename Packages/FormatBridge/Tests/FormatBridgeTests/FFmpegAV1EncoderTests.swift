import Testing
import Foundation
import FormatBridge

@Suite("FormatBridge in-process AV1 encode (#58)")
struct FFmpegAV1EncoderTests {

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("av1-\(UUID().uuidString).mp4")
    }
    private func bytes(_ u: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
    }

    @Test("transcodes an h264 source → valid AV1/MP4 in-process (no external ffmpeg)")
    func encodesAV1() async throws {
        let out = tmp(); defer { try? FileManager.default.removeItem(at: out) }
        try FFmpegAV1Encoder.encode(source: fixtureURL("sample.mp4"), output: out,
                                    settings: .init(crf: 40, preset: 10))
        #expect(FileManager.default.fileExists(atPath: out.path))

        // Probe the OUTPUT with FormatBridge's own probe — proves it's a real, decodable AV1.
        let info = try await FormatBridgeFactory.makeProbe().probe(url: out)
        let v = try #require(info.videoStreams.first)
        print("[av1] \(v.codec.rawValue) \(v.width)x\(v.height)  \(bytes(out)) bytes  colour=\(v.colorSpace.map { "\($0)" } ?? "nil")")
        #expect(v.codec == .av1, "output must be AV1, got \(v.codec.rawValue)")
        #expect(v.width == 320 && v.height == 240)
    }

    @Test("film-grain synthesis param is accepted and still produces valid AV1")
    func filmGrain() async throws {
        let out = tmp(); defer { try? FileManager.default.removeItem(at: out) }
        try FFmpegAV1Encoder.encode(source: fixtureURL("sample.mp4"), output: out,
                                    settings: .init(crf: 45, preset: 12, filmGrain: 8))
        let info = try await FormatBridgeFactory.makeProbe().probe(url: out)
        #expect(info.videoStreams.first?.codec == .av1)
    }

    @Test("maxFrames caps the encode (the CRF-search probe path)")
    func maxFramesCap() async throws {
        let full = tmp(), capped = tmp()
        defer { try? FileManager.default.removeItem(at: full); try? FileManager.default.removeItem(at: capped) }
        try FFmpegAV1Encoder.encode(source: fixtureURL("sample.mp4"), output: full,
                                    settings: .init(crf: 50, preset: 12))
        try FFmpegAV1Encoder.encode(source: fixtureURL("sample.mp4"), output: capped,
                                    settings: .init(crf: 50, preset: 12, maxFrames: 10))
        print("[av1] full(48f)=\(bytes(full))  capped(10f)=\(bytes(capped))")
        #expect(bytes(capped) > 0 && bytes(capped) < bytes(full), "10-frame probe must be smaller than the full clip")
    }
}
