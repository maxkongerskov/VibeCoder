//
//  HardwareInfo.swift
//
//  Detect the running Mac's CPU brand and unified-memory size.
//  Drives hardware-fit hints in onboarding + Discover tab + catalog
//  recommendations. macOS-only; no graceful degradation for Linux
//  builds (CLI on Linux gets a generic fallback string).
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct HardwareInfo: Sendable, Equatable {

    public let cpuLabel: String        // e.g. "M3 Ultra"
    public let unifiedMemoryGB: Int    // e.g. 512

    public init(cpuLabel: String, unifiedMemoryGB: Int) {
        self.cpuLabel = cpuLabel
        self.unifiedMemoryGB = unifiedMemoryGB
    }

    public static func detect() -> HardwareInfo {
        let memoryGB = detectMemoryGB()
        let cpuLabel = detectCPUBrand()
        return HardwareInfo(cpuLabel: cpuLabel, unifiedMemoryGB: memoryGB)
    }

    // MARK: - Internals

    private static func detectMemoryGB() -> Int {
        let bytes = Double(ProcessInfo.processInfo.physicalMemory)
        // macOS reports physical memory in slightly-less-than-power-of-2 bytes
        // (e.g. 511.something GiB on a 512 GB machine). Round to nearest 8 GB
        // — Apple Silicon Macs come in 8/16/24/32/48/64/96/128/192/256/512 GB
        // tiers, all multiples of 8.
        let raw = bytes / (1024 * 1024 * 1024)
        let nearest8 = (raw / 8.0).rounded() * 8.0
        return Int(nearest8)
    }

    private static func detectCPUBrand() -> String {
        #if canImport(Darwin)
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let raw = String(cString: buffer)
        // "Apple M3 Ultra" → "M3 Ultra"
        return raw.hasPrefix("Apple ") ? String(raw.dropFirst(6)) : raw
        #else
        return "Unknown"
        #endif
    }
}
