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
    FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
    let fileHandle = try FileHandle(forWritingTo: temporaryURL)
    defer { try? fileHandle.close() }

    let (bytes, response) = try await session.bytes(from: descriptor.downloadURL)
    guard let response = response as? HTTPURLResponse,
          response.statusCode == 200, response.url?.scheme == "https" else {
      throw LocalModelCatalogError.invalidResponse
    }

    var bufferedBytes = [UInt8]()
    bufferedBytes.reserveCapacity(64 * 1_024)
    var receivedByteCount: Int64 = 0
    for try await byte in bytes {
      try Task.checkCancellation()
      bufferedBytes.append(byte)
      receivedByteCount += 1
      guard receivedByteCount <= descriptor.expectedByteCount else {
        throw LocalModelCatalogError.unexpectedDownloadSize(expected: descriptor.expectedByteCount, actual: receivedByteCount)
      }
      if bufferedBytes.count == bufferedBytes.capacity {
        try fileHandle.write(contentsOf: Data(bufferedBytes))
        bufferedBytes.removeAll(keepingCapacity: true)
        await progress(ModelDownloadProgress(
          receivedByteCount: receivedByteCount,
          expectedByteCount: descriptor.expectedByteCount
        ))
      }
    }
    if !bufferedBytes.isEmpty {
      try fileHandle.write(contentsOf: Data(bufferedBytes))
    }
    await progress(ModelDownloadProgress(
      receivedByteCount: receivedByteCount,
      expectedByteCount: descriptor.expectedByteCount
    ))

    guard receivedByteCount == descriptor.expectedByteCount else {
      throw LocalModelCatalogError.unexpectedDownloadSize(
        expected: descriptor.expectedByteCount,
        actual: receivedByteCount
      )
    }
    guard try sha256(of: temporaryURL).caseInsensitiveCompare(descriptor.checksumSHA256) == .orderedSame else {
      throw LocalModelCatalogError.checksumMismatch
    }

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
