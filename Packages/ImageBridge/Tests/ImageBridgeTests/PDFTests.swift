import Testing
import Foundation
import CoreGraphics
import CoreVideo
@testable import ImageBridge

@Suite("ImageBridge PDF rasterization (Phase 3)")
struct PDFTests {

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("ibp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A 2-page PDF, 144×72 pt pages: page 1 solid red, page 2 solid blue.
    private func makeTwoPagePDF(_ url: URL) {
        var box = CGRect(x: 0, y: 0, width: 144, height: 72)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(color)
            ctx.fill(box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Center-pixel BGRA bytes of a decoded (premultiplied BGRA) buffer.
    private func centerBGRA(_ pb: CVPixelBuffer) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let o = (h / 2) * stride + (w / 2) * 4
        return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))
    }

    @Test("probe + decode rasterize every page at the target DPI")
    func decodesAllPages() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("doc.pdf"); makeTwoPagePDF(pdf)

        let m = try ImageBridgeFactory.makeProbe().probe(url: pdf)
        #expect(m.format == .pdf)
        #expect(m.frameCount == 2, "two pages")
        #expect(m.alpha == .none, "PDFs flatten onto opaque white")
        // 144×72 pt at the default 150 DPI → 300×150 px.
        #expect(m.width == 300 && m.height == 150, "got \(m.width)x\(m.height)")

        let (frames, _) = try ImageBridgeFactory.makeDecoder().decode(url: pdf)
        #expect(frames.count == 2)
        // Look at pixels: page 1 is red, page 2 is blue (per-page rasterization, not page-1 twice).
        let p1 = centerBGRA(frames[0]), p2 = centerBGRA(frames[1])
        print("[pdf] page1 BGR=\(p1)  page2 BGR=\(p2)")
        #expect(p1.r > 200 && p1.b < 60, "page 1 red")
        #expect(p2.b > 200 && p2.r < 60, "page 2 blue")
    }

    @Test("convertSequence fans a multi-page PDF out to per-page files")
    func multiPageOutput() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("doc.pdf"); makeTwoPagePDF(pdf)
        let out = dir.appendingPathComponent("page.png")

        let written = try ImageBridgeFactory.makeOrchestrator().convertSequence(
            input: pdf, output: out, settings: StillEncoderSettings(format: .png),
            frameProcessor: nil)

        #expect(written.count == 2)
        #expect(written[0].lastPathComponent == "page-001.png")
        #expect(written[1].lastPathComponent == "page-002.png")
        for url in written {
            #expect(FileManager.default.fileExists(atPath: url.path))
            let m = try ImageBridgeFactory.makeProbe().probe(url: url)
            #expect(m.format == .png && m.width == 300 && m.height == 150)
        }
    }
}
