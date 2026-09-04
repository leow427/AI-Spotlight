import Darwin
import Foundation
import Metal

struct LocalHardwareProfile: Codable, Sendable, Equatable {
  static let gib: Int64 = 1_073_741_824
  var physicalMemory: Int64
  var isAppleSilicon: Bool
  var hasMetal: Bool
  var hasUnifiedMemory: Bool
  var chip: String
  var device: String
  var cpuCount: Int
  var performanceCPUCount: Int
  var availableDiskBytes: Int64
  var metalRecommendedWorkingSet: Int64?
  var metalMaximumBufferLength: Int64?
  var lowPowerMode: Bool

  // Never lend the OS reserve to inference, even on very large-memory Macs.
  var osReserve: Int64 { max(4 * Self.gib, physicalMemory / 4) }
  var inferenceMemoryBudget: Int64 {
    var budget = min(physicalMemory * 3 / 5, max(0, physicalMemory - osReserve))
    if hasMetal, let metalRecommendedWorkingSet {
      budget = min(budget, metalRecommendedWorkingSet * 4 / 5)
    }
    return max(0, budget)
  }

  // No serial numbers or stable personal/device identifiers are collected.
  var fingerprint: String {
    [chip, device, String(physicalMemory), String(cpuCount), String(hasMetal),
     String(hasUnifiedMemory), String(metalRecommendedWorkingSet ?? 0)].joined(separator: "|")
  }

  static func detect(modelsDirectory: URL) -> Self {
    let metal = MTLCreateSystemDefaultDevice()
    let process = ProcessInfo.processInfo
    return Self(
      physicalMemory: Int64(clamping: process.physicalMemory),
      isAppleSilicon: integer("hw.optional.arm64") == 1,
      hasMetal: metal != nil,
      hasUnifiedMemory: metal?.hasUnifiedMemory ?? false,
      chip: string("machdep.cpu.brand_string") ?? "Unknown processor",
      device: string("hw.model") ?? "Mac",
      cpuCount: process.activeProcessorCount,
      performanceCPUCount: Int(integer("hw.perflevel0.physicalcpu") ?? Int64(process.processorCount)),
      availableDiskBytes: availableDisk(at: modelsDirectory),
      metalRecommendedWorkingSet: metal.map { Int64(clamping: $0.recommendedMaxWorkingSetSize) },
      metalMaximumBufferLength: metal.map { Int64(clamping: $0.maxBufferLength) },
      lowPowerMode: process.isLowPowerModeEnabled
    )
  }

  static func availableDisk(at directory: URL) -> Int64 {
    var existing = directory
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
      existing.deleteLastPathComponent()
    }
    // Non-purgeable free space is deliberately more conservative than
    // volumeAvailableCapacityForImportantUsage, which includes reclaimable files.
    return (try? FileManager.default.attributesOfFileSystem(forPath: existing.path)[.systemFreeSize]
      as? NSNumber)?.int64Value ?? 0
  }

  private static func integer(_ key: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
    return value
  }

  private static func string(_ key: String) -> String? {
    var size = 0
    guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
    return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }
}
