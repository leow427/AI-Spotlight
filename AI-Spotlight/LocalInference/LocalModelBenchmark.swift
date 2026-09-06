import Foundation

struct LocalBenchmarkMetrics: Codable, Sendable, Equatable {
  let timeToFirstToken: Double
  let generationTokensPerSecond: Double
  let promptTokensPerSecond: Double
  let peakMemoryBytes: Int64
  let promptTokenCount: Int
  let generatedTokenCount: Int
  let modelLoadSeconds: Double

  var isValid: Bool {
    [timeToFirstToken, generationTokensPerSecond, promptTokensPerSecond, modelLoadSeconds]
      .allSatisfy { $0.isFinite && $0 >= 0 }
      && timeToFirstToken > 0 && generationTokensPerSecond > 0 && promptTokensPerSecond > 0
      && peakMemoryBytes > 0 && promptTokenCount > 0 && generatedTokenCount >= 16
  }
}

struct LocalModelBenchmark: Codable, Sendable, Equatable {
  static let version = 1
  let version: Int
  let llamaBuild: Int
  let hardwareFingerprint: String
  let lowPowerMode: Bool
  let modelID: String
  let modelChecksum: String
  let modelByteCount: Int64
  let parameterBillions: Double
  let architecture: String
  let contextSize: Int
  let recordedAt: Date
  let metrics: LocalBenchmarkMetrics
  let predictedTokensPerSecond: Double
  let predictedTimeToFirstToken: Double

  var underperformed: Bool {
    metrics.generationTokensPerSecond < predictedTokensPerSecond * 0.6
      || metrics.timeToFirstToken > max(5, predictedTimeToFirstToken * 1.75)
  }

  func isApplicable(to hardware: LocalHardwareProfile, now: Date = .now) -> Bool {
    version == Self.version && llamaBuild == (architecture == "qwen3vl" ? LocalVisionRuntime.build : LocalModelCompatibility.llamaBuild)
      && hardwareFingerprint == hardware.fingerprint && lowPowerMode == hardware.lowPowerMode
      && recordedAt <= now && now.timeIntervalSince(recordedAt) < 90 * 86_400 && metrics.isValid
  }
}
