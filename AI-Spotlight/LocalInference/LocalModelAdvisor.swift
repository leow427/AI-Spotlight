import Combine
import Foundation

@MainActor
final class LocalModelAdvisor: ObservableObject {
  static let shared = LocalModelAdvisor()

  @Published private(set) var hardware: LocalHardwareProfile?
  @Published private(set) var manifest = LocalModelManifest.bundled
  @Published private(set) var measurements: [LocalModelBenchmark] = []
  @Published private(set) var notice: String?
  @Published private(set) var isDetecting = false
  @Published var isOnboardingPresented = false
  private let directory: URL
  private let modelsDirectory: URL
  private let defaults: UserDefaults
  private let updater: LocalCatalogUpdater
  private let detect: @Sendable (URL) -> LocalHardwareProfile
  private var initialized = false

  init(
    directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight/Model Recommendations"),
    modelsDirectory: URL = LocalModelInstallationStore().modelsDirectoryURL,
    defaults: UserDefaults = .standard,
    trust: LocalCatalogTrust? = .configured,
    detect: @escaping @Sendable (URL) -> LocalHardwareProfile = LocalHardwareProfile.detect
  ) {
    self.directory = directory
    self.modelsDirectory = modelsDirectory
    self.defaults = defaults
    self.detect = detect
    updater = LocalCatalogUpdater(directory: directory, trust: trust)
    if let data = try? Data(contentsOf: directory.appending(path: "benchmarks.json")),
       let saved = try? JSONDecoder().decode([LocalModelBenchmark].self, from: data) {
      measurements = Array(saved.filter { $0.metrics.isValid }.suffix(100))
    }
  }

  func start(installedModels: [LocalModel]) async {
    guard !initialized else { return }
    initialized = true
    await detectHardware()
    if installedModels.isEmpty && !defaults.bool(forKey: "localModelOnboardingDismissed") {
      isOnboardingPresented = true
    }
    await refreshCatalog()
  }

  func detectHardware() async {
    guard !isDetecting else { return }
    isDetecting = true
    let directory = modelsDirectory
    let detect = detect
    let profile = await Task.detached(priority: .utility) { detect(directory) }.value
    hardware = profile
    do {
      try save(profile, name: "hardware.json")
    } catch { notice = "Could not save the Mac capability report: \(error.localizedDescription)" }
    isDetecting = false
  }

  func refreshCatalog(force: Bool = false) async {
    manifest = await updater.catalog(force: force)
  }

  func recommendations(installedModels: [LocalModel]) -> LocalModelRecommendations {
    guard let hardware else {
      return LocalModelRecommendations(assessments: [], recommended: nil, faster: nil, smarter: nil)
    }
    return LocalModelSelector.select(manifest: manifest, hardware: hardware,
      measurements: measurements, installedIDs: Set(installedModels.map(\.id)))
  }

  func confirmDownload(_ model: LocalModelDescriptor, installedModels: [LocalModel]) async throws -> LocalModelAssessment {
    await detectHardware()
    guard let assessment = recommendations(installedModels: installedModels).assessments.first(where: { $0.model == model }),
          assessment.canInstall else {
      throw LocalInferenceError.bridgeFailure("This model no longer fits the available resources. Refresh the model choices.")
    }
    return assessment
  }

  func record(_ metrics: LocalBenchmarkMetrics, model: LocalModel, prediction: LocalModelAssessment?) {
    guard let hardware, metrics.isValid else { return }
    let descriptor = model.catalogDescriptor
    let record = LocalModelBenchmark(
      version: LocalModelBenchmark.version, llamaBuild: model.catalogDescriptor?.runtimeBuild ?? LocalModelCompatibility.llamaBuild,
      hardwareFingerprint: hardware.fingerprint, lowPowerMode: hardware.lowPowerMode,
      modelID: model.id, modelChecksum: descriptor?.checksumSHA256 ?? "unverified-import",
      modelByteCount: descriptor?.expectedByteCount ?? 0, parameterBillions: descriptor?.parameterBillions ?? 0,
      architecture: descriptor?.architecture ?? "unverified", contextSize: descriptor?.recommendedContextSize ?? ModelContextPolicy.localContextWindow,
      recordedAt: .now, metrics: metrics,
      predictedTokensPerSecond: prediction?.tokensPerSecond ?? metrics.generationTokensPerSecond,
      predictedTimeToFirstToken: prediction?.timeToFirstToken ?? metrics.timeToFirstToken
    )
    measurements.append(record)
    measurements = Array(measurements.suffix(100))
    do { try save(measurements, name: "benchmarks.json") }
    catch { notice = "The benchmark finished, but its results could not be saved: \(error.localizedDescription)" }
  }

  func latestBenchmark(for model: LocalModel?) -> LocalModelBenchmark? {
    guard let model, let hardware else { return nil }
    return measurements.last { $0.modelID == model.id && $0.isApplicable(to: hardware)
      && $0.modelChecksum == (model.catalogDescriptor?.checksumSHA256 ?? "unverified-import") }
  }

  func dismissOnboarding() {
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    isOnboardingPresented = false
  }

  func replayOnboarding() async {
    await detectHardware()
    isOnboardingPresented = true
  }

  private func save<T: Encodable>(_ value: T, name: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: directory.appending(path: name), options: .atomic)
  }
}
