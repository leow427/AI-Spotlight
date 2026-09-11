import CryptoKit
import Foundation

struct LocalModelDescriptor: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let displayName: String
  let downloadURL: URL
  let expectedByteCount: Int64
  let license: String
  let checksumSHA256: String
  let revision: String
  let quantization: String
  let architecture: String
  let chatTemplate: String
  let minimumLlamaBuild: Int
  let estimatedRuntimeMemory: Int64
  let largestTensorBytes: Int64
  let recommendedContextSize: Int
  let qualityScore: Double
  let performanceClass: String
  let parameterBillions: Double
  let minimumMemory: Int64
  let recommendedMemory: Int64
  // Optional for decoding existing text-only installations and old signed catalogs.
  var projector: VerifiedModelArtifact? = nil
  var runtimeBuild: Int? = nil
  var publisher: String? = nil
  var modelSummary: String? = nil
  var inferenceProfile: LocalMultimodalProfile? = nil
  var advertisedMemoryRange: String? = nil
  var modelSupportsAudio: Bool? = nil

  var summary: String {
    modelSummary ?? (supportsVision ? "A local model for general text answers and screenshot understanding."
      : "A legacy text-only model for chat and OCR text; direct image input is unsupported.")
  }
  var maker: String { publisher ?? (architecture == "qwen3vl" ? "Alibaba / Qwen" : "Imported model") }
  var resolvedProfile: LocalMultimodalProfile? {
    inferenceProfile ?? LocalMultimodalProfile.legacyQwen(parameters: parameterBillions)
  }

  /// Memory estimates guide recommendations, but users may intentionally install
  /// any compatible package after seeing its warning. Artifact and runtime
  /// validation remain required; this does not admit an unsupported architecture.
  var permitsMemoryOverride: Bool {
    supportsVision && LocalModelCompatibility.supports(self) && (try? validate()) != nil
  }

  var downloadByteCount: Int64 {
    expectedByteCount + (projector?.expectedByteCount ?? 0)
      + (projector == nil ? 0 : LocalVisionRuntime.bundled.archive.expectedByteCount)
  }

  var packageRevision: String {
    "\(revision):\(checksumSHA256):\(projector?.checksumSHA256 ?? "text"):\(runtimeBuild ?? 5046)"
  }

  func requiresUpdate(_ installed: LocalModel) -> Bool {
    installed.id == id && (installed.catalogDescriptor?.packageRevision != packageRevision
      || installed.catalogDescriptor?.expectedByteCount != expectedByteCount
      || installed.catalogDescriptor?.projector?.expectedByteCount != projector?.expectedByteCount
      || (supportsVision && (installed.visionConfiguration?.packageRevision != packageRevision
        || installed.visionConfiguration?.contextWindow != recommendedContextSize
        || !FileManager.default.isExecutableFile(atPath: installed.visionConfiguration?.serverExecutableURL.path ?? ""))))
  }

  var visionDescriptor: LocalVisionModelDescriptor? {
    guard let projector else { return nil }
    return LocalVisionModelDescriptor(id: id, displayName: displayName,
      summary: summary,
      model: VerifiedModelArtifact(url: downloadURL, expectedByteCount: expectedByteCount, checksumSHA256: checksumSHA256),
      projector: projector, estimatedRuntimeMemory: estimatedRuntimeMemory)
  }

  func validate() throws {
    let components = downloadURL.pathComponents
    guard !id.isEmpty, id.count <= 160, !displayName.isEmpty,
          downloadURL.scheme == "https", downloadURL.host == "huggingface.co",
          downloadURL.user == nil, downloadURL.password == nil, downloadURL.port == nil,
          downloadURL.pathExtension == "gguf", components.count == 6,
          components[3] == "resolve", components[4] == revision,
          revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
          expectedByteCount > 0, expectedByteCount <= 1_000_000_000_000,
          checksumSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          !license.isEmpty, !quantization.isEmpty, !architecture.isEmpty, !chatTemplate.isEmpty,
          minimumLlamaBuild > 0, estimatedRuntimeMemory > expectedByteCount,
          estimatedRuntimeMemory <= 2_000_000_000_000,
          largestTensorBytes > 0, largestTensorBytes <= estimatedRuntimeMemory,
          (256...131_072).contains(recommendedContextSize),
          qualityScore.isFinite, (0...100).contains(qualityScore),
          !performanceClass.isEmpty, parameterBillions.isFinite, parameterBillions > 0,
          publisher.map({ !$0.isEmpty && $0.count <= 100 }) ?? true,
          modelSummary.map({ !$0.isEmpty && $0.count <= 300 && !$0.contains("\n") }) ?? true,
          minimumMemory >= estimatedRuntimeMemory, recommendedMemory >= minimumMemory else {
      throw LocalModelCatalogError.invalidManifest(id)
    }
    if let projector {
      try visionDescriptor!.validate()
      guard runtimeBuild == LocalVisionRuntime.build,
            let profile = resolvedProfile,
            estimatedRuntimeMemory >= profile.memory(weights: expectedByteCount,
              projector: projector.expectedByteCount, context: recommendedContextSize) else {
        throw LocalModelCatalogError.invalidManifest(id)
      }
    } else if runtimeBuild != nil { throw LocalModelCatalogError.invalidManifest(id) }
  }
  static func multimodalMemory(weights: Int64, projector: Int64, parameters: Double, context: Int) -> Int64 {
    // Qwen3-VL dense: 36 layers (4/8B), 64 (32B), 8 KV heads, 128 head dim.
    // Full F16 K + V cache; 20% weight overhead plus 2 GiB for vision/compute/runtime.
    let layers: Int64 = parameters > 8 ? 64 : 36
    let kv = layers * 8 * 128 * 4 * Int64(context)
    return Int64(Double(weights + projector) * 1.2) + kv + 2 * LocalHardwareProfile.gib
  }
}

/// Reviewed against publisher configs and the pinned runtime; full-context F16
/// cache is reserved even for sliding/shared KV layers, avoiding optimistic fits.
enum LocalMultimodalProfile: String, Codable, CaseIterable, Sendable {
  case qwen3VL4B, qwen3VL8B, qwen3VL32B
  case gemma4E2B, gemma4E4B, gemma4_12B, gemma4A4B, gemma4_31B
  case ministral3B, ministral8B, ministral14B
  case miniCPMV4, miniCPMV45
  case smolVLM2, qwen35_4B, qwen35_9B, miniCPMO45

  static func legacyQwen(parameters: Double) -> Self? {
    switch parameters { case 4: .qwen3VL4B; case 8: .qwen3VL8B; case 32: .qwen3VL32B; default: nil }
  }

  var architecture: String {
    switch self {
    case .qwen3VL4B, .qwen3VL8B, .qwen3VL32B: "qwen3vl"
    case .gemma4E2B, .gemma4E4B, .gemma4_12B, .gemma4A4B, .gemma4_31B: "gemma4"
    case .ministral3B, .ministral8B, .ministral14B: "mistral3"
    case .miniCPMV4: "llama"
    case .miniCPMV45, .miniCPMO45: "qwen3"
    case .smolVLM2: "llama"
    case .qwen35_4B, .qwen35_9B: "qwen35"
    }
  }

  var chatTemplate: String {
    switch self {
    case .qwen3VL4B, .qwen3VL8B, .qwen3VL32B: "qwen3-vl-instruct"
    case .gemma4E2B, .gemma4E4B, .gemma4_12B, .gemma4A4B, .gemma4_31B: "gemma4-instruct"
    case .ministral3B, .ministral8B, .ministral14B: "ministral3-instruct"
    case .miniCPMV4: "minicpm-v4"
    case .miniCPMV45: "minicpm-v4.5"
    case .miniCPMO45: "minicpm-o4.5"
    case .smolVLM2: "smolvlm2"
    case .qwen35_4B, .qwen35_9B: "qwen3.5"
    }
  }

  var parameters: Double {
    switch self {
    case .qwen3VL4B: 4; case .qwen3VL8B: 8; case .qwen3VL32B: 32
    case .gemma4E2B: 4.6; case .gemma4E4B: 7.5; case .gemma4_12B: 12
    case .gemma4A4B: 26; case .gemma4_31B: 31
    case .ministral3B: 3.4; case .ministral8B: 8.5; case .ministral14B: 13.5
    case .miniCPMV4: 3.6; case .miniCPMV45: 8.2
    case .miniCPMO45: 9; case .smolVLM2: 2.2
    case .qwen35_4B: 4; case .qwen35_9B: 9
    }
  }

  var quantizations: [String] {
    architecture == "gemma4" ? ["Q4_0", "Q4_K_M", "Q5_K_M"] : ["Q4_K_M", "Q5_K_M", "Q8_0"]
  }

  var cacheBytesPerToken: Int64 {
    // K and V are both F16 (4 bytes together); Gemma global and sliding
    // layers use different head dimensions/head counts. PLE/MoE weights
    // are already included in the actual artifact bytes, never active params.
    switch self {
    case .qwen3VL4B, .qwen3VL8B, .miniCPMV45, .miniCPMO45: 36 * 8 * 128 * 4
    case .qwen3VL32B: 64 * 8 * 128 * 4
    case .gemma4E2B: (28 * 1 * 256 + 7 * 1 * 512) * 4
    case .gemma4E4B: (35 * 2 * 256 + 7 * 2 * 512) * 4
    case .gemma4_12B: (40 * 8 * 256 + 8 * 1 * 512) * 4
    case .gemma4A4B: (25 * 8 * 256 + 5 * 2 * 512) * 4
    case .gemma4_31B: (50 * 16 * 256 + 10 * 4 * 512) * 4
    case .ministral3B: 26 * 8 * 128 * 4
    case .ministral8B: 34 * 8 * 128 * 4
    case .ministral14B: 40 * 8 * 128 * 4
    case .miniCPMV4: 32 * 2 * 128 * 4
    case .smolVLM2: 24 * 32 * 64 * 4
    case .qwen35_4B, .qwen35_9B: 8 * 4 * 256 * 4
    }
  }

  func memory(weights: Int64, projector: Int64, context: Int) -> Int64 {
    Int64(Double(weights + projector) * 1.2) + cacheBytesPerToken * Int64(context)
      + 2 * LocalHardwareProfile.gib
  }
}

struct LocalModelManifest: Codable, Sendable, Equatable {
  let version: Int
  let models: [LocalModelDescriptor]

  func validate() throws {
    guard version > 0, !models.isEmpty, models.count <= 200,
          Set(models.map(\.id)).count == models.count,
          Set(models.map(\.checksumSHA256)).count == models.count else {
      throw LocalModelCatalogError.invalidManifest("catalog")
    }
    try models.forEach { try $0.validate() }
  }

  static let bundled = LocalModelManifest(version: 5, models: BundledLocalModels.models)
}

struct ModelDownloadProgress: Sendable, Equatable {
  let receivedByteCount: Int64
  let expectedByteCount: Int64

  var fractionCompleted: Double {
    guard expectedByteCount > 0 else { return 0 }
    return min(1, Double(receivedByteCount) / Double(expectedByteCount))
  }
}

enum LocalModelCatalogError: LocalizedError, Equatable {
  case invalidManifest(String)
  case unexpectedDownloadSize(expected: Int64, actual: Int64)
  case checksumMismatch
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .invalidManifest(let id):
      "The model manifest entry \(id) is invalid."
    case .unexpectedDownloadSize:
      "The downloaded model size did not match the manifest."
    case .checksumMismatch:
      "The downloaded model checksum did not match the manifest."
    case .invalidResponse:
      "The model server returned an invalid response."
    }
  }
}

struct LocalModelCatalog: Sendable {
  private let installationStore: LocalModelInstallationStore
  private let session: URLSession
  private let detectHardware: @Sendable (URL) -> LocalHardwareProfile
  private let availableDisk: @Sendable (URL) -> Int64

  init(
    installationStore: LocalModelInstallationStore,
    session: URLSession = .shared,
    detectHardware: @escaping @Sendable (URL) -> LocalHardwareProfile = LocalHardwareProfile.detect,
    availableDisk: @escaping @Sendable (URL) -> Int64 = LocalHardwareProfile.availableDisk
  ) {
    self.installationStore = installationStore
    self.session = session
    self.detectHardware = detectHardware
    self.availableDisk = availableDisk
  }

  func download(
    _ descriptor: LocalModelDescriptor,
    runtime: LocalVisionRuntime = .bundled,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel {
    try descriptor.validate()
    guard descriptor.supportsVision else {
      throw LocalInferenceError.bridgeFailure("Choose a recommended model that supports text and images. Existing text-only files remain available.")
    }
    let hardware = detectHardware(installationStore.modelsDirectoryURL)
    let assessment = LocalModelSelector.assess(descriptor, hardware: hardware)
    guard assessment.canInstall else { throw LocalInferenceError.bridgeFailure(assessment.reason) }
    return try await downloadVision(descriptor.visionDescriptor!, runtime: runtime, catalogDescriptor: descriptor, progress: progress)
  }

  func downloadVision(
    _ descriptor: LocalVisionModelDescriptor,
    runtime: LocalVisionRuntime = .bundled,
    catalogDescriptor: LocalModelDescriptor? = nil,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel {
    try descriptor.validate()
    try runtime.validate()
    let directory = installationStore.modelsDirectoryURL
    let hardware = detectHardware(directory)
    guard hardware.inferenceMemoryBudget >= descriptor.estimatedRuntimeMemory
      || catalogDescriptor?.permitsMemoryOverride == true else {
      throw LocalInferenceError.bridgeFailure("This model does not leave enough memory for macOS, image processing and context. Review Local Models for a suitable package.")
    }
    let total = descriptor.model.expectedByteCount + descriptor.projector.expectedByteCount + runtime.archive.expectedByteCount
    guard availableDisk(directory) >= total * 2 + 2 * LocalHardwareProfile.gib else {
      throw LocalInferenceError.bridgeFailure("Free more disk space before downloading this image model.")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let staging = directory.appending(path: ".vision-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    let runtimeDirectory = directory.appending(path: "vision-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    var committed = false
    defer {
      try? FileManager.default.removeItem(at: staging)
      if !committed { try? FileManager.default.removeItem(at: runtimeDirectory) }
    }
    let artifacts = [descriptor.model, descriptor.projector, runtime.archive]
    let names = ["model.gguf", "mmproj.gguf", "runtime.tar.gz"]
    var completed: Int64 = 0
    for (artifact, name) in zip(artifacts, names) {
      let offset = completed
      try await artifact.download(to: staging.appending(path: name), session: session) { update in
        await progress(ModelDownloadProgress(receivedByteCount: offset + update.receivedByteCount,
                                             expectedByteCount: total))
      }
      completed += artifact.expectedByteCount
    }
    try Task.checkCancellation()
    // Keep room for the model/projector copies and the extracted runtime.
    guard availableDisk(directory) >= total + 2 * LocalHardwareProfile.gib else {
      throw LocalInferenceError.bridgeFailure("Free disk space changed during the download. Free some space and try again.")
    }
    let server = try await runtime.install(archive: staging.appending(path: "runtime.tar.gz"),
                                           staging: staging, destination: runtimeDirectory)
    try Task.checkCancellation()
    let installed = try installationStore.install(LocalModel(id: descriptor.id, displayName: descriptor.displayName,
      fileURL: staging.appending(path: "model.gguf"), catalogDescriptor: catalogDescriptor,
      visionConfiguration: LocalVisionConfiguration(projectorURL: staging.appending(path: "mmproj.gguf"),
        serverExecutableURL: server, contextWindow: catalogDescriptor?.recommendedContextSize ?? 8192,
        managedRuntimeDirectory: runtimeDirectory, packageRevision: catalogDescriptor?.packageRevision ?? descriptor.packageRevision)))
    committed = true
    return installed
  }
}

/// The same bounded, checksum-verified transfer is used for text models and
/// every part of a vision download. Callers own staging and atomic installation.
struct VerifiedModelArtifact: Codable, Sendable, Equatable {
  let url: URL
  let expectedByteCount: Int64
  let checksumSHA256: String

  func validate() throws {
    guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
          expectedByteCount > 0, expectedByteCount <= 1_000_000_000_000,
          checksumSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
      throw LocalModelCatalogError.invalidManifest("download")
    }
  }

  func download(to temporaryURL: URL, session: URLSession,
                progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws {
    try validate()
    try Task.checkCancellation()
    let updates = AsyncStream<ModelDownloadProgress>.makeStream()
    let delegate = ModelArtifactDownloadDelegate(expectedByteCount: expectedByteCount, updates: updates.continuation)
    let reporter = Task {
      for await update in updates.stream { await progress(update) }
    }
    do {
      // The async URLSession download convenience does not deliver download
      // progress callbacks. A delegate-backed task also enforces the size limit
      // while bytes arrive, instead of waiting for an oversized file to finish.
      let downloadSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
      defer { downloadSession.invalidateAndCancel() }
      let task = downloadSession.downloadTask(with: url)
      let response = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          delegate.start(task, destination: temporaryURL, continuation: continuation)
        }
      } onCancel: { delegate.cancel() }
      guard let response = response as? HTTPURLResponse,
            response.statusCode == 200, response.url?.scheme == "https" else {
        throw LocalModelCatalogError.invalidResponse
      }
      let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard Int64(size) == expectedByteCount else {
        throw LocalModelCatalogError.unexpectedDownloadSize(expected: expectedByteCount, actual: Int64(size))
      }
      updates.continuation.yield(ModelDownloadProgress(receivedByteCount: Int64(size), expectedByteCount: expectedByteCount))
      updates.continuation.finish()
      await reporter.value
      try Task.checkCancellation()
      guard try sha256(of: temporaryURL).caseInsensitiveCompare(checksumSHA256) == .orderedSame else {
        throw LocalModelCatalogError.checksumMismatch
      }
    } catch {
      updates.continuation.finish()
      await reporter.value
      if let oversized = delegate.oversizedByteCount {
        throw LocalModelCatalogError.unexpectedDownloadSize(expected: expectedByteCount, actual: oversized)
      }
      throw error
    }
  }

  private func sha256(of fileURL: URL) throws -> String {
    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { try? fileHandle.close() }
    var hash = SHA256()
    while true {
      try Task.checkCancellation()
      let data = try fileHandle.read(upToCount: 1_048_576) ?? Data()
      guard !data.isEmpty else { break }
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private final class ModelArtifactDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  let expectedByteCount: Int64
  let updates: AsyncStream<ModelDownloadProgress>.Continuation
  private let lock = NSLock()
  private var oversized: Int64?
  private var task: URLSessionDownloadTask?
  private var destination: URL?
  private var continuation: CheckedContinuation<URLResponse, Error>?
  private var result: Result<URLResponse, Error>?
  private var cancelled = false
  var oversizedByteCount: Int64? { lock.withLock { oversized } }
  init(expectedByteCount: Int64, updates: AsyncStream<ModelDownloadProgress>.Continuation) {
    self.expectedByteCount = expectedByteCount
    self.updates = updates
  }
  func start(_ task: URLSessionDownloadTask, destination: URL,
             continuation: CheckedContinuation<URLResponse, Error>) {
    let shouldCancel = lock.withLock {
      self.task = task
      self.destination = destination
      self.continuation = continuation
      return cancelled
    }
    // Cancellation can arrive before the continuation/task has been registered.
    if shouldCancel { task.cancel() }
    task.resume()
  }

  func cancel() {
    let active = lock.withLock { cancelled = true; return task }
    active?.cancel()
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    let outcome = Result<URLResponse, Error> {
      guard let destination = lock.withLock({ self.destination }), let response = downloadTask.response else {
        throw LocalModelCatalogError.invalidResponse
      }
      // URLSession deletes this temporary file when the delegate returns.
      try FileManager.default.moveItem(at: location, to: destination)
      return response
    }
    lock.withLock { result = outcome }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let completion = lock.withLock {
      let outcome: Result<URLResponse, Error> = error.map { .failure($0) }
        ?? result ?? .failure(LocalModelCatalogError.invalidResponse)
      let waiting = continuation
      continuation = nil
      self.task = nil
      return (waiting, outcome)
    }
    completion.0?.resume(with: completion.1)
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard totalBytesWritten <= expectedByteCount else {
      lock.withLock { oversized = totalBytesWritten }
      downloadTask.cancel()
      return
    }
    updates.yield(ModelDownloadProgress(receivedByteCount: totalBytesWritten, expectedByteCount: expectedByteCount))
  }
}

struct LocalVisionModelDescriptor: Sendable, Equatable, Identifiable {
  let id: String
  let displayName: String
  let summary: String
  let model: VerifiedModelArtifact
  let projector: VerifiedModelArtifact
  let estimatedRuntimeMemory: Int64
  var downloadByteCount: Int64 {
    model.expectedByteCount + projector.expectedByteCount + LocalVisionRuntime.bundled.archive.expectedByteCount
  }
  var modelCardURL: URL { model.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

  var packageRevision: String { model.url.deletingLastPathComponent().lastPathComponent }

  func requiresUpdate(_ installed: LocalModel) -> Bool {
    guard installed.id == id, let configuration = installed.visionConfiguration else { return false }
    if let revision = configuration.packageRevision { return revision != packageRevision }
    return true
  }

  func validate() throws {
    try model.validate()
    try projector.validate()
    guard !id.isEmpty, !displayName.isEmpty, estimatedRuntimeMemory > model.expectedByteCount + projector.expectedByteCount,
          model.url != projector.url else { throw LocalModelCatalogError.invalidManifest(id) }
    for artifact in [model, projector] {
      try artifact.validate()
      let path = artifact.url.pathComponents
      guard artifact.url.host == "huggingface.co", (path.count == 6 || (path.count == 7 && path[5] == "vision")), ["ggml-org", "Qwen", "google", "mistralai", "openbmb", "unsloth", "bartowski"].contains(path[1]),
            path[3] == "resolve", path[4].range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
            artifact.url.pathExtension == "gguf",
            Array(path.prefix(5)) == Array(model.url.pathComponents.prefix(5)) else {
        throw LocalModelCatalogError.invalidManifest(id)
      }
    }
  }

  // Internal package adapter; the ordinary catalog is the only recommendation source.
  static var bundled: [LocalVisionModelDescriptor] { BundledLocalModels.models.compactMap(\.visionDescriptor) }
}
