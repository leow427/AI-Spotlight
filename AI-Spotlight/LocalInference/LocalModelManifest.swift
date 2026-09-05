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
          minimumMemory >= estimatedRuntimeMemory, recommendedMemory >= minimumMemory else {
      throw LocalModelCatalogError.invalidManifest(id)
    }
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

  static let bundled = LocalModelManifest(version: 1, models: BundledLocalModels.models)
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
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel {
    try descriptor.validate()
    let hardware = detectHardware(installationStore.modelsDirectoryURL)
    let assessment = LocalModelSelector.assess(descriptor, hardware: hardware)
    guard assessment.fit.canRun else { throw LocalInferenceError.bridgeFailure(assessment.reason) }
    try FileManager.default.createDirectory(
      at: installationStore.modelsDirectoryURL,
      withIntermediateDirectories: true
    )

    let temporaryURL = installationStore.modelsDirectoryURL.appending(
      path: ".downloading-\(UUID().uuidString).gguf"
    )
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try await VerifiedModelArtifact(url: descriptor.downloadURL,
      expectedByteCount: descriptor.expectedByteCount, checksumSHA256: descriptor.checksumSHA256)
      .download(to: temporaryURL, session: session, progress: progress)

    try Task.checkCancellation()
    // Recheck free space before the installer makes its second copy.
    guard availableDisk(installationStore.modelsDirectoryURL)
      >= descriptor.expectedByteCount + 2 * LocalHardwareProfile.gib else {
      throw LocalInferenceError.bridgeFailure("Free disk space changed during the download. Free some space and try again.")
    }
    return try installationStore.install(
      LocalModel(
        id: descriptor.id,
        displayName: descriptor.displayName,
        fileURL: temporaryURL,
        catalogDescriptor: descriptor
      )
    )
  }

  func downloadVision(
    _ descriptor: LocalVisionModelDescriptor,
    runtime: LocalVisionRuntime = .bundled,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel {
    try descriptor.validate()
    try runtime.validate()
    let directory = installationStore.modelsDirectoryURL
    let hardware = detectHardware(directory)
    guard hardware.inferenceMemoryBudget >= descriptor.estimatedRuntimeMemory else {
      throw LocalInferenceError.bridgeFailure("This image model needs more available memory. Choose a smaller model or close other apps.")
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
      fileURL: staging.appending(path: "model.gguf"),
      visionConfiguration: LocalVisionConfiguration(projectorURL: staging.appending(path: "mmproj.gguf"),
        serverExecutableURL: server, managedRuntimeDirectory: runtimeDirectory)))
    committed = true
    return installed
  }
}

/// The same bounded, checksum-verified transfer is used for text models and
/// every part of a vision download. Callers own staging and atomic installation.
struct VerifiedModelArtifact: Sendable, Equatable {
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
      let (downloaded, response) = try await session.download(from: url, delegate: delegate)
      defer { try? FileManager.default.removeItem(at: downloaded) }
      guard let response = response as? HTTPURLResponse,
            response.statusCode == 200, response.url?.scheme == "https" else {
        throw LocalModelCatalogError.invalidResponse
      }
      let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard Int64(size) == expectedByteCount else {
        throw LocalModelCatalogError.unexpectedDownloadSize(expected: expectedByteCount, actual: Int64(size))
      }
      updates.continuation.yield(ModelDownloadProgress(receivedByteCount: Int64(size), expectedByteCount: expectedByteCount))
      updates.continuation.finish()
      await reporter.value
      try Task.checkCancellation()
      try FileManager.default.moveItem(at: downloaded, to: temporaryURL)
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
  var oversizedByteCount: Int64? { lock.withLock { oversized } }
  init(expectedByteCount: Int64, updates: AsyncStream<ModelDownloadProgress>.Continuation) {
    self.expectedByteCount = expectedByteCount
    self.updates = updates
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
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

  func validate() throws {
    guard !id.isEmpty, !displayName.isEmpty, estimatedRuntimeMemory > model.expectedByteCount + projector.expectedByteCount,
          model.url != projector.url else { throw LocalModelCatalogError.invalidManifest(id) }
    for artifact in [model, projector] {
      try artifact.validate()
      let path = artifact.url.pathComponents
      guard artifact.url.host == "huggingface.co", path.count == 6, path[1] == "ggml-org",
            path[3] == "resolve", path[4].range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
            artifact.url.pathExtension == "gguf",
            artifact.url.deletingLastPathComponent() == model.url.deletingLastPathComponent() else {
        throw LocalModelCatalogError.invalidManifest(id)
      }
    }
  }

  static let bundled: [LocalVisionModelDescriptor] = [
    LocalVisionModelDescriptor(id: "smolvlm-500m-q8:vision", displayName: "SmolVLM 500M",
      summary: "Small download · Start here for simple photos and objects.",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/ggml-org/SmolVLM-500M-Instruct-GGUF/resolve/72e986006ef53e37cdd3f6d4241c90b0f01df376/SmolVLM-500M-Instruct-Q8_0.gguf")!,
        expectedByteCount: 436806912, checksumSHA256: "9d4612de6a42214499e301494a3ecc2be0abdd9de44e663bda63f1152fad1bf4"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/ggml-org/SmolVLM-500M-Instruct-GGUF/resolve/72e986006ef53e37cdd3f6d4241c90b0f01df376/mmproj-SmolVLM-500M-Instruct-Q8_0.gguf")!,
        expectedByteCount: 108783360, checksumSHA256: "d1eb8b6b23979205fdf63703ed10f788131a3f812c7b1f72e0119d5d81295150"),
      estimatedRuntimeMemory: 2 * LocalHardwareProfile.gib),
    LocalVisionModelDescriptor(id: "smolvlm-2b-q4:vision", displayName: "SmolVLM 2.2B",
      summary: "Larger model · For more detailed image descriptions.",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/ggml-org/SmolVLM-Instruct-GGUF/resolve/e75618fdae83145c487f1b4d8115bb02a5b58ecc/SmolVLM-Instruct-Q4_K_M.gguf")!,
        expectedByteCount: 1112242368, checksumSHA256: "dc80966bd84789de64115f07888939c03abb1714d431c477dfb405517a554af5"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/ggml-org/SmolVLM-Instruct-GGUF/resolve/e75618fdae83145c487f1b4d8115bb02a5b58ecc/mmproj-SmolVLM-Instruct-Q8_0.gguf")!,
        expectedByteCount: 592521344, checksumSHA256: "86b84aa7babf1ab51a6366d973b9d380354e92c105afaa4f172cc76d044da739"),
      estimatedRuntimeMemory: 4 * LocalHardwareProfile.gib)
  ]
}
