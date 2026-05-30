import Foundation

/// Orchestrates full conversion: probe → decode → [optimize] → encode.
public protocol ConversionOrchestrating: Sendable {
    func convert(
        input: URL,
        output: URL,
        settings: ConversionSettings,
        progress: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws
}
