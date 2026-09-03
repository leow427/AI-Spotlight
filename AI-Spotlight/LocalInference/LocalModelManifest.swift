import CryptoKit
import Foundation

struct LocalModelDescriptor: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let displayName: String
  let downloadURL: URL
  let expectedByteCount: Int64
  let license: String
  let checksumSHA256: String

  func validate() throws {
    guard downloadURL.scheme == "https",
          expectedByteCount > 0,
          checksumSHA256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
      throw LocalModelCatalogError.invalidManifest(id)
    }
  }
}

struct LocalModelManifest: Sendable, Equatable {
  let models: [LocalModelDescriptor]

  static let bundled = LocalModelManifest(models: [
    LocalModelDescriptor(
      id: "qwen2.5-1.5b-instruct-q4-k-m",
      displayName: "Qwen 2.5 1.5B Instruct (Q4_K_M)",
      downloadURL: URL(string: "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/d6f592509429a0f25fc337a6d05065356c40d2b2/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf?download=true")!,
      expectedByteCount: 986_048_768,
      license: "Apache-2.0",
      checksumSHA256: "1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370"
    ),
  ])
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

  init(installationStore: LocalModelInstallationStore) {
    self.installationStore = installationStore
  }

  func download(
    _ descriptor: LocalModelDescriptor,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel {
    try descriptor.validate()
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

    let (bytes, response) = try await URLSession.shared.bytes(from: descriptor.downloadURL)
    guard let response = response as? HTTPURLResponse,
          (200...299).contains(response.statusCode) else {
      throw LocalModelCatalogError.invalidResponse
    }

    var bufferedBytes = [UInt8]()
    bufferedBytes.reserveCapacity(64 * 1_024)
    var receivedByteCount: Int64 = 0
    for try await byte in bytes {
      try Task.checkCancellation()
      bufferedBytes.append(byte)
      receivedByteCount += 1
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

    return try installationStore.install(
      LocalModel(
        id: descriptor.id,
        displayName: descriptor.displayName,
        fileURL: temporaryURL
      )
    )
  }

  private func sha256(of fileURL: URL) throws -> String {
    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { try? fileHandle.close() }
    var hash = SHA256()
    while true {
      let data = try fileHandle.read(upToCount: 1_048_576) ?? Data()
      guard !data.isEmpty else { break }
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
