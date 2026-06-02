import COxipng
import Foundation

/// Lossless PNG re-compression via oxipng (ImageBridge Phase 2, ADR-0020) — the
/// "pngcrush but keeps quality" pass. Lossless by construction: pixels are
/// preserved exactly, so there is no quality trade-off; the output is ≤ the input.
enum OxipngOptimizer {

    /// Optimize the PNG at `url` in place (atomic temp-then-replace).
    static func optimizeInPlace(_ url: URL, level: UInt8, stripMetadata: Bool) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".oxi-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rc: Int32 = url.path.withCString { ip in
            tmp.path.withCString { op in
                oxipng_optimize_file(ip, op, level, stripMetadata)
            }
        }
        guard rc == 0, FileManager.default.fileExists(atPath: tmp.path) else {
            throw ImageBridgeError.encodeFailed("oxipng optimize failed (rc=\(rc))")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
