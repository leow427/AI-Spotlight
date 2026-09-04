import Foundation

enum LocalModelCompatibility {
  // Tied to Packages/LlamaBridge/Package.swift. A remote catalog cannot expand
  // native capabilities; new architectures require an app/bridge review.
  static let llamaBuild = 5_046
  static let minimumContext = 4_096

  static func supports(_ model: LocalModelDescriptor) -> Bool {
    model.minimumLlamaBuild <= llamaBuild && model.architecture == "qwen2"
      && model.chatTemplate == "chatml"
      && ["Q4_K_M", "Q5_K_M", "Q8_0"].contains(model.quantization)
      && model.recommendedContextSize >= minimumContext
      && model.recommendedContextSize <= 32_768
  }
}

enum LocalModelFit: String, Sendable {
  case excellent = "Excellent fit"
  case good = "Good fit"
  case slow = "May be slow"
  case memory = "Insufficient memory"
  case disk = "Insufficient disk space"
  case unsupported = "Unsupported"

  var canRun: Bool { self == .excellent || self == .good || self == .slow }
}

struct LocalModelAssessment: Identifiable, Sendable {
  let model: LocalModelDescriptor
  let fit: LocalModelFit
  let reason: String
  let tokensPerSecond: Double
  let timeToFirstToken: Double
  let isMeasured: Bool
  var id: String { model.id }
  var isResponsive: Bool { fit.canRun && tokensPerSecond >= 8 && timeToFirstToken <= 5 }
  var performanceDescription: String {
    if !fit.canRun { return reason }
    let prefix = isMeasured ? "Measured" : "Estimated"
    return "\(prefix) \(Int(tokensPerSecond.rounded())) tokens/sec · "
      + (isResponsive ? "Responsive everyday chat" : "Longer waits for replies")
  }
}

struct LocalModelRecommendations: Sendable {
  let assessments: [LocalModelAssessment]
  let recommended: LocalModelAssessment?
  let faster: LocalModelAssessment?
  let smarter: LocalModelAssessment?

  func fasterAlternative(to modelID: String) -> LocalModelAssessment? {
    guard let current = assessments.first(where: { $0.id == modelID }) else { return nil }
    return assessments.filter {
      $0.id != modelID && $0.isResponsive
        && $0.model.estimatedRuntimeMemory < current.model.estimatedRuntimeMemory
        && $0.tokensPerSecond >= current.tokensPerSecond * 1.2
    }.sorted(by: LocalModelSelector.qualityOrder).first
  }
}

enum LocalModelSelector {
  static func select(
    manifest: LocalModelManifest, hardware: LocalHardwareProfile,
    measurements: [LocalModelBenchmark] = [], installedIDs: Set<String> = []
  ) -> LocalModelRecommendations {
    let assessments = manifest.models.map {
      assess($0, hardware: hardware, measurements: measurements, installed: installedIDs.contains($0.id))
    }
    // Safety is a gate, not a term in a score that quality can outweigh.
    let responsive = assessments.filter(\.isResponsive).sorted(by: qualityOrder)
    let recommended = responsive.first
    let faster = recommended.flatMap { current in
      responsive.filter {
        $0.id != current.id && $0.model.estimatedRuntimeMemory < current.model.estimatedRuntimeMemory
          && $0.tokensPerSecond >= current.tokensPerSecond * 1.2
      }.first
    }
    let smarter = recommended.flatMap { current in
      assessments.filter {
        $0.fit.canRun && $0.model.qualityScore > current.model.qualityScore
          && $0.tokensPerSecond >= 3 && $0.timeToFirstToken <= 12
      }.sorted(by: qualityOrder).first
    }
    return LocalModelRecommendations(assessments: assessments, recommended: recommended,
                                     faster: faster, smarter: smarter)
  }

  static func qualityOrder(_ lhs: LocalModelAssessment, _ rhs: LocalModelAssessment) -> Bool {
    if lhs.model.qualityScore != rhs.model.qualityScore {
      return lhs.model.qualityScore > rhs.model.qualityScore
    }
    if lhs.tokensPerSecond != rhs.tokensPerSecond { return lhs.tokensPerSecond > rhs.tokensPerSecond }
    return lhs.id < rhs.id
  }

  static func assess(
    _ model: LocalModelDescriptor, hardware: LocalHardwareProfile,
    measurements: [LocalModelBenchmark] = [], installed: Bool = false
  ) -> LocalModelAssessment {
    let usable = measurements.filter { $0.isApplicable(to: hardware) }
    let exact = usable.filter { $0.modelChecksum == model.checksumSHA256
      && $0.contextSize == model.recommendedContextSize }.max { $0.recordedAt < $1.recordedAt }
    let estimate = prediction(model, hardware: hardware, measurements: usable)
    let speed = exact?.metrics.generationTokensPerSecond ?? estimate.speed
    let ttft = exact?.metrics.timeToFirstToken ?? estimate.ttft
    func result(_ fit: LocalModelFit, _ reason: String) -> LocalModelAssessment {
      LocalModelAssessment(model: model, fit: fit, reason: reason, tokensPerSecond: speed,
                           timeToFirstToken: ttft, isMeasured: exact != nil)
    }
    guard (try? model.validate()) != nil, LocalModelCompatibility.supports(model) else {
      return result(.unsupported, "Requires an unsupported architecture, chat format, context, or llama.cpp build.")
    }
    // The bridge uses GPU offload when Metal exists. Discrete GPU memory needs
    // a separately validated policy; do not assume it is unified CPU memory.
    guard !hardware.hasMetal || (hardware.isAppleSilicon && hardware.hasUnifiedMemory) else {
      return result(.unsupported, "This catalog currently supports Apple unified-memory Metal or CPU inference.")
    }
    if hardware.hasMetal, let bufferLimit = hardware.metalMaximumBufferLength,
       model.largestTensorBytes > bufferLimit {
      return result(.unsupported, "This model requires larger Metal buffers than this Mac supports.")
    }
    let runtimeMemory = max(model.estimatedRuntimeMemory, exact?.metrics.peakMemoryBytes ?? 0)
    guard hardware.physicalMemory >= model.minimumMemory,
          runtimeMemory <= hardware.inferenceMemoryBudget else {
      return result(.memory, "Does not leave enough memory for macOS and other apps.")
    }
    // Installation copies the verified download before committing the library.
    let requiredDisk = model.expectedByteCount * 2 + 2 * LocalHardwareProfile.gib
    guard installed || hardware.availableDiskBytes >= requiredDisk else {
      return result(.disk, "Needs room for the download, installation copy, and 2 GB of free space.")
    }
    if speed < 8 || ttft > 5 { return result(.slow, "Fits in memory, but replies may take longer.") }
    let comfortable = runtimeMemory <= hardware.inferenceMemoryBudget * 4 / 5
      && hardware.physicalMemory >= model.recommendedMemory
    return result(comfortable ? .excellent : .good, "Fits with memory reserved for macOS.")
  }

  private static func prediction(
    _ model: LocalModelDescriptor, hardware: LocalHardwareProfile, measurements: [LocalModelBenchmark]
  ) -> (speed: Double, ttft: Double) {
    // Conservative throughput prior based on resources, never chip-name tables.
    // It is a heuristic, not advertised memory bandwidth or a measured benchmark.
    let cores = Double(max(1, min(hardware.performanceCPUCount, hardware.cpuCount)))
    let bandwidth = hardware.hasMetal ? min(100, 18 + cores * 5) : min(16, cores * 2)
    let weightsGiB = Double(model.expectedByteCount) / Double(LocalHardwareProfile.gib)
    var speed = bandwidth / max(0.5, weightsGiB)
    var promptSpeed = (hardware.hasMetal ? cores * 80 : cores * 12) / max(1, model.parameterBillions)
    if hardware.lowPowerMode { speed *= 0.65; promptSpeed *= 0.65 }
    // Calibrate from the latest same-architecture run. Limit upward extrapolation
    // to 2x the resource prior; exact measurements above already take precedence.
    if let latest = measurements.filter({ $0.architecture == model.architecture }).max(by: { $0.recordedAt < $1.recordedAt }) {
      speed = min(speed * 2, latest.metrics.generationTokensPerSecond
        * Double(latest.modelByteCount) / Double(model.expectedByteCount))
      promptSpeed = min(promptSpeed * 2, latest.metrics.promptTokensPerSecond
        * latest.parameterBillions / model.parameterBillions)
    }
    return (speed, 256 / max(1, promptSpeed) + 1 / max(0.1, speed))
  }
}
