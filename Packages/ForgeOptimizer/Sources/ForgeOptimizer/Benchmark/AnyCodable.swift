//
// AnyCodable.swift
// ForgeOptimizer / Benchmark
//
// Type-erased Codable wrapper used by `CompressionMetrics.encoderSettings`
// — the schema marks `encoder_settings` as a free-form object so the
// harness can capture whatever VideoToolbox / encoder knobs the run
// produced without needing a schema bump.
//
// The `Any` payload defeats `Sendable` automation, so this is
// `@unchecked Sendable`. Only assign decoded primitives (Bool, Int,
// Double, String, arrays, dictionaries) — never reference types — so
// the wrapper stays safe to ship across actors.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import Foundation

/// A type-erased Codable wrapper for the freeform encoder_settings field.
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let v = try? container.decode(Bool.self) {
            self.value = v
        } else if let v = try? container.decode(Int.self) {
            self.value = v
        } else if let v = try? container.decode(Double.self) {
            self.value = v
        } else if let v = try? container.decode(String.self) {
            self.value = v
        } else if let v = try? container.decode([AnyCodable].self) {
            self.value = v
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self.value = v
        } else {
            self.value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [AnyCodable]: try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        default: try container.encodeNil()
        }
    }
}
