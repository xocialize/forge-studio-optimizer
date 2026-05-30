import Foundation

/// Inspects input files, detects container/codec, and determines the conversion tier.
public protocol MediaProbing: Sendable {
    func probe(url: URL) async throws -> MediaInfo
}
