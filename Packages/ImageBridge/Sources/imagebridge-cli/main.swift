import CoreVideo
import Foundation
import ImageBridge

// `imagebridge` — turn a recurring client deliverable (a vector PDF, or any raster)
// into a crisp, optimized image. The headline use: rasterize a vector PDF at high DPI
// so dense signage text stays SHARP (no SR hallucination — the pixels come from the
// vector, not a guess), then optimize the output (lossless oxipng PNG, or quality-knob
// HEIC/AVIF/JPEG). Pure ImageIO/CoreGraphics/oxipng — no models, no MLX.

let usage = """
imagebridge — vector(PDF)→crisp high-DPI raster + optimize (also raster convert + optimize)

USAGE:
  imagebridge --input <file> [options]

OPTIONS:
  -i, --input <path>      Input file (PDF | PNG | JPEG | HEIC | TIFF | AVIF). Required.
  -o, --output <path>     Output path. Default: <input-stem>.<format> beside the input.
                          Multi-page PDFs append -001, -002, … to the stem.
  -f, --format <fmt>      png | avif | heic | jpeg | tiff.  Default: png.
      --dpi <N>           Rasterize vector input at N DPI (vector only). Default: 300.
      --long-edge <px>    Rasterize so the longest side ≈ px (vector only; overrides --dpi).
  -q, --quality <0..1>    Lossy quality for heic/avif/jpeg. Default: 0.9.
      --oxipng-level <0-6> Lossless PNG optimizer effort. Default: 4.
      --strip             Drop ICC/EXIF/DPI metadata on write.
  -h, --help              Show this help.

EXAMPLES:
  imagebridge -i venue-map.pdf --dpi 300 -f png            # crisp 300-DPI PNG (lossless)
  imagebridge -i venue-map.pdf --long-edge 7680 -f avif -q 0.92
  imagebridge -i photo.jpg -f avif -q 0.8                  # raster: convert + shrink
"""

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data("error: \(msg)\n\n\(usage)\n".utf8)); exit(2) }
func human(_ bytes: Int) -> String {
    bytes >= 1_048_576 ? String(format: "%.2f MB", Double(bytes) / 1_048_576)
        : bytes >= 1024 ? String(format: "%.1f KB", Double(bytes) / 1024) : "\(bytes) B"
}

// MARK: - parse args

var input: String?, output: String?, formatStr = "png"
var dpi = 300.0, longEdge: Double?, quality = 0.9, oxiLevel: UInt8 = 4, strip = false

var it = CommandLine.arguments.dropFirst().makeIterator()
func next(_ flag: String) -> String {
    guard let v = it.next() else { fail("\(flag) needs a value") }
    return v
}
func dbl(_ flag: String) -> Double {
    let s = next(flag); guard let v = Double(s) else { fail("\(flag) must be a number, got '\(s)'") }
    return v
}
while let a = it.next() {
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "-i", "--input": input = next(a)
    case "-o", "--output": output = next(a)
    case "-f", "--format": formatStr = next(a).lowercased()
    case "--dpi": dpi = dbl(a)
    case "--long-edge": longEdge = dbl(a)
    case "-q", "--quality": quality = dbl(a)
    case "--oxipng-level":
        let s = next(a); guard let v = UInt8(s) else { fail("--oxipng-level must be 0..6") }; oxiLevel = v
    case "--strip": strip = true
    default:
        if a.hasPrefix("-") { fail("unknown option: \(a)") }
        else if input == nil { input = a } else { fail("unexpected argument: \(a)") }
    }
}

guard let inPath = input else { fail("missing --input") }
guard FileManager.default.fileExists(atPath: inPath) else { fail("no such file: \(inPath)") }
if formatStr == "jpg" { formatStr = "jpeg" }
guard let format = StillOutputFormat(rawValue: formatStr) else { fail("unsupported --format: \(formatStr)") }

let inURL = URL(filePath: inPath)
let isPDF = inURL.pathExtension.lowercased() == "pdf"

// MARK: - resolve DPI (vector only)

if longEdge != nil && !isPDF {
    FileHandle.standardError.write(Data("note: --long-edge applies to vector (PDF) input only; ignored for raster.\n".utf8))
}
if isPDF, let edge = longEdge {
    // Point dims = pixels probed at 72 DPI. dpi to hit the target longest edge.
    let pts = try ImageBridgeFactory.makeProbe(pdfDPI: 72).probe(url: inURL)
    let maxPt = Double(max(pts.width, pts.height))
    guard maxPt > 0 else { fail("could not read PDF page size") }
    dpi = min(2400, max(36, edge * 72.0 / maxPt))   // clamp to a sane range
}

// MARK: - output path

let extByFormat: [StillOutputFormat: String] = [.png: "png", .jpeg: "jpg", .heic: "heic", .avif: "avif", .tiff: "tiff"]
let outExt = extByFormat[format]!
let outURL = output.map { URL(filePath: $0) }
    ?? inURL.deletingPathExtension().appendingPathExtension(outExt)

// MARK: - run

do {
    let inInfo = try ImageBridgeFactory.makeProbe(pdfDPI: dpi).probe(url: inURL)
    let inBytes = (try? FileManager.default.attributesOfItem(atPath: inPath)[.size] as? Int) ?? 0
    let dpiNote = isPDF ? " @ \(Int(dpi)) DPI → \(inInfo.width)x\(inInfo.height)px" : ""
    print("input : \(inURL.lastPathComponent)  \(inInfo.format.rawValue) \(inInfo.width)x\(inInfo.height)"
        + (isPDF ? " pt" : "")  + "  \(human(inBytes))" + (inInfo.frameCount > 1 ? "  (\(inInfo.frameCount) pages)" : "") + dpiNote)

    let settings = StillEncoderSettings(format: format, quality: quality,
                                        stripMetadata: strip, losslessOptimize: true, optimizeLevel: oxiLevel)
    let written = try ImageBridgeFactory.makeOrchestrator(pdfDPI: dpi)
        .convertSequence(input: inURL, output: outURL, settings: settings, frameProcessor: nil)

    for url in written {
        let m = try ImageBridgeFactory.makeProbe().probe(url: url)
        let b = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("output: \(url.lastPathComponent)  \(format.rawValue) \(m.width)x\(m.height)  \(human(b))")
    }
    let total = written.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
    print("done  : \(written.count) file(s), \(human(total)) total")
} catch {
    fail("\(error)")
}
