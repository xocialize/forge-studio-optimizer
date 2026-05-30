//
// HardwareProbe.swift
// ForgeOptimizer / Benchmark
//
// Captures the `HardwareInfo` block of a benchmark report by reading
// sysctl + ProcessInfo + IOKit. The thermal-state field is critical —
// per schema §1, a throughput claim under thermal pressure isn't the
// same claim as one measured cold.
//
// GPU-core count has no clean Apple API; left nil. The chip parser
// maps `machdep.cpu.brand_string` to the schema-friendly form ("M5 Max"
// instead of "Apple M5 Max"); unrecognized brand strings fall back to
// the raw brand string.
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import Foundation
import IOKit
import IOKit.ps

/// Snapshots the host hardware into a `HardwareInfo` payload.
///
/// Synchronous — none of the underlying APIs block long enough to need
/// an actor. Lives in `Benchmark/` because its only consumer is the
/// benchmark report emission path.
public struct HardwareProbe: Sendable {

    public init() {}

    /// Capture the current hardware snapshot.
    public func snapshot() -> HardwareInfo {
        let model = Self.sysctlString("hw.model") ?? "unknown"
        let brand = Self.sysctlString("machdep.cpu.brand_string") ?? ""
        let chip = Self.parseChip(brand)
        let cpuCores = Self.sysctlInt("hw.physicalcpu")
        let gpuCores: Int? = nil  // no clean API; left nil per task scope
        let memBytes = Self.sysctlUInt64("hw.memsize") ?? 0
        let memoryGB = Double(memBytes) / (1024.0 * 1024.0 * 1024.0)
        let osVersion = Self.osVersionString()
        let thermal = Self.thermalState()
        let onBattery = Self.onBattery()

        return HardwareInfo(
            modelIdentifier: model,
            chip: chip,
            cpuCores: cpuCores,
            gpuCores: gpuCores,
            memoryGB: memoryGB,
            osVersion: osVersion,
            thermalState: thermal,
            onBattery: onBattery
        )
    }

    // MARK: - sysctl helpers

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        // Strip trailing NULs.
        return String(cString: buffer)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(value)
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    // MARK: - Chip parser

    /// Map an "Apple M5 Max" brand string to "M5 Max" (the schema example
    /// form). Unrecognized brand strings fall through unchanged.
    static func parseChip(_ brand: String) -> String {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }

        // Strip the "Apple " prefix if present.
        var s = trimmed
        if s.hasPrefix("Apple ") {
            s = String(s.dropFirst("Apple ".count))
        }

        // Known shapes: "M4 Pro", "M5 Pro", "M5 Max", "M4 Max", plain "M5".
        // Walk the string and accept anything that starts with M<digit>(s)
        // optionally followed by " Pro" / " Max" / " Ultra".
        let pattern = #"^(M\d+)(\s+(Pro|Max|Ultra))?\b"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(s.startIndex..., in: s)
            if let match = regex.firstMatch(in: s, options: [], range: range),
               let r = Range(match.range, in: s) {
                return String(s[r])
            }
        }

        // Last-resort fallback: return the (de-Apple-prefixed) brand.
        return s
    }

    // MARK: - OS version

    static func osVersionString() -> String {
        // ProcessInfo's string is "Version 15.5 (Build 24F74)"; strip the
        // "Version " prefix and the build tag for the schema's
        // "macOS 15.5" form.
        let raw = ProcessInfo.processInfo.operatingSystemVersionString
        var v = raw
        if v.hasPrefix("Version ") {
            v = String(v.dropFirst("Version ".count))
        }
        if let parenRange = v.range(of: " (") {
            v = String(v[..<parenRange.lowerBound])
        }
        return "macOS " + v.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Thermal

    static func thermalState() -> HardwareInfo.ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    // MARK: - Battery

    static func onBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for src in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, src)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = info[kIOPSPowerSourceStateKey as String] as? String,
               state == kIOPSBatteryPowerValue as String {
                return true
            }
        }
        return false
    }
}
