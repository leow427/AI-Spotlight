import Combine
import CryptoKit
import Foundation

struct HuggingFaceRepositoryFile: Decodable, Identifiable, Hashable, Sendable {
  struct LFS: Decodable, Hashable, Sendable {
    let sha256: String
    let size: Int64
  }
  let rfilename: String
  let size: Int64
  let blobId: String
  var lfs: LFS? = nil
  var id: String { rfilename }
  var isWeight: Bool {
    ["gguf", "safetensors", "bin", "onnx", "pt", "pth", "h5", "tflite", "msgpack"].contains(
      URL(fileURLWithPath: rfilename).pathExtension.lowercased())
  }
  var isProjector: Bool { rfilename.lowercased().contains("mmproj") || rfilename.hasPrefix("vision/") }

  func validate() throws {
    let parts = rfilename.components(separatedBy: "/")
    guard !rfilename.isEmpty, rfilename.utf8.count <= 1024, !rfilename.contains("\\"),
          !rfilename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }),
          size >= 0, size <= 1_000_000_000_000,
          blobId.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
      throw ModelDiscoveryError.invalidResponse
    }
    if let lfs {
      guard lfs.size == size, size > 0,
            lfs.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        throw ModelDiscoveryError.invalidResponse
      }
    }
  }
}

struct HuggingFaceRepository: Decodable, Sendable {
  let id: String
  let sha: String
  let siblings: [HuggingFaceRepositoryFile]

  func validate() throws {
    guard HuggingFaceModelListing(id: id).hasValidID,
          sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
          !siblings.isEmpty, siblings.count <= 10_000 else { throw ModelDiscoveryError.invalidResponse }
    try siblings.forEach { try $0.validate() }
    let paths = siblings.map { $0.rfilename.precomposedStringWithCanonicalMapping.lowercased() }
    guard Set(paths).count == paths.count else { throw ModelDiscoveryError.invalidResponse }
  }

  func url(for file: HuggingFaceRepositoryFile) -> URL {
    URL(string: "https://huggingface.co")!.appending(path: id)
      .appending(path: "resolve/\(sha)/\(file.rfilename)")
  }

  var suggestedFiles: Set<String> {
    let gguf = siblings.filter { $0.rfilename.lowercased().hasSuffix(".gguf") }
    if !gguf.isEmpty {
      // A GGUF repository often contains dozens of alternative quantizations.
      // Pick one Q4 family (including all shards), never all weight variants.
      let weights = gguf.filter { !$0.isProjector }
      let preferred = weights.filter { $0.rfilename.uppercased().contains("Q4_K_M") }
      let first = (preferred.isEmpty ? weights : preferred).sorted { $0.id < $1.id }.first
      func family(_ path: String) -> String {
        path.replacingOccurrences(of: "-\\d{5}-of-\\d{5}\\.gguf$", with: ".gguf", options: .regularExpression)
      }
      let selected = first.map { first in weights.filter { family($0.id) == family(first.id) } } ?? []
      let projectors = gguf.filter(\.isProjector)
      let projector = projectors.first {
        $0.rfilename.lowercased().range(of: "[._-]f16\\.gguf$", options: .regularExpression) != nil
      }
        ?? projectors.first
      return Set((selected + [projector].compactMap { $0 }).map(\.id))
    }
    // Complete non-GGUF snapshots include configuration/tokenizer files so they
    // can be used in an appropriate external runtime. Nothing is executed.
    return Set(siblings.map(\.id))
  }
}

enum HuggingFaceRepositoryClient {
  static func load(_ id: String) async throws -> HuggingFaceRepository {
    guard HuggingFaceModelListing(id: id).hasValidID else { throw ModelDiscoveryError.invalidResponse }
    var components = URLComponents(url: URL(string: "https://huggingface.co/api/models")!.appending(path: id),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 25
    configuration.timeoutIntervalForResource = 40
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(from: components.url!)
    guard let http = response as? HTTPURLResponse, http.url?.scheme == "https",
          http.url?.host == "huggingface.co" else { throw ModelDiscoveryError.invalidResponse }
    if http.statusCode == 401 || http.statusCode == 403 { throw HuggingFaceDownloadError.accessRequired }
    if http.statusCode == 429 { throw ModelDiscoveryError.rateLimited }
    guard http.statusCode == 200 else { throw ModelDiscoveryError.unavailable }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < 8_000_000 else { throw ModelDiscoveryError.responseTooLarge }
      data.append(byte)
    }
    let repository = try JSONDecoder().decode(HuggingFaceRepository.self, from: data)
    guard repository.id == id else { throw ModelDiscoveryError.invalidResponse }
    try repository.validate()
    return repository
  }
}

enum HuggingFaceDownloadError: LocalizedError {
  case accessRequired, invalidSelection, checksumMismatch
  var errorDescription: String? {
    switch self {
    case .accessRequired: "This model requires Hugging Face access approval or sign-in before its files can be downloaded."
    case .invalidSelection: "Choose at least one file from this model’s current file list."
    case .checksumMismatch: "A downloaded file did not match its published checksum. Please retry."
    }
  }
}

struct HuggingFaceFileDownloader: Sendable {
  typealias Transfer = @Sendable (HuggingFaceRepositoryFile, URL, URL,
    @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> Void
  var transfer: Transfer = { file, url, output, progress in
    try await Self.transfer(file, from: url, to: output, progress: progress)
  }

  func download(_ repository: HuggingFaceRepository, selected: Set<String>, into parent: URL,
    progress: @escaping @Sendable (String, ModelDownloadProgress) async -> Void) async throws -> URL {
    try repository.validate()
    let files = repository.siblings.filter { selected.contains($0.id) }
    guard !files.isEmpty, files.count == selected.count else { throw HuggingFaceDownloadError.invalidSelection }
    let total = files.reduce(Int64(0)) { $0 + $1.size }
    let name = "\(repository.id.replacingOccurrences(of: "/", with: "--"))-\(repository.sha.prefix(8))-\(UUID().uuidString.prefix(8))"
    let destination = parent.appending(path: name, directoryHint: .isDirectory)
    let staging = parent.appending(path: ".enigma-download-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    var completed: Int64 = 0
    for file in files {
      try Task.checkCancellation()
      let output = staging.appending(path: file.rfilename)
      try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      let offset = completed
      try await transfer(file, repository.url(for: file), output) { update in
        await progress(file.rfilename, ModelDownloadProgress(receivedByteCount: offset + update.receivedByteCount,
          expectedByteCount: total))
      }
      completed += file.size
    }
    try Task.checkCancellation()
    // Commit the complete snapshot by renaming on the same volume. A failed or
    // cancelled transfer never replaces a previously downloaded model.
    try FileManager.default.moveItem(at: staging, to: destination)
    return destination
  }

  static func transfer(_ file: HuggingFaceRepositoryFile, from url: URL, to output: URL,
    configuration: URLSessionConfiguration = .ephemeral,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws {
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    if let lfs = file.lfs {
      try await VerifiedModelArtifact(url: url, expectedByteCount: file.size, checksumSHA256: lfs.sha256)
        .download(to: output, session: session, progress: progress)
      return
    }
    // Ordinary Git files use the Git blob SHA-1; large model weights use the
    // existing SHA-256 verified, disk-backed download path above.
    let (bytes, response) = try await session.bytes(from: url)
    guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else {
      throw ModelDiscoveryError.invalidResponse
    }
    if http.statusCode == 401 || http.statusCode == 403 { throw HuggingFaceDownloadError.accessRequired }
    guard http.statusCode == 200 else { throw ModelDiscoveryError.unavailable }
    guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    var hash = Insecure.SHA1()
    hash.update(data: Data("blob \(file.size)\0".utf8))
    var received: Int64 = 0
    var buffer = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      received += 1
      guard received <= file.size else {
        throw LocalModelCatalogError.unexpectedDownloadSize(expected: file.size, actual: received)
      }
      buffer.append(byte)
      if buffer.count == 65_536 {
        try handle.write(contentsOf: buffer)
        hash.update(data: buffer)
        buffer.removeAll(keepingCapacity: true)
        await progress(ModelDownloadProgress(receivedByteCount: received, expectedByteCount: file.size))
      }
    }
    try handle.write(contentsOf: buffer)
    hash.update(data: buffer)
    guard received == file.size else {
      throw LocalModelCatalogError.unexpectedDownloadSize(expected: file.size, actual: received)
    }
    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.blobId else {
      throw HuggingFaceDownloadError.checksumMismatch
    }
    await progress(ModelDownloadProgress(receivedByteCount: received, expectedByteCount: file.size))
  }
}

@MainActor
final class HuggingFaceModelDownloads: ObservableObject {
  static let shared = HuggingFaceModelDownloads()
  @Published private(set) var repositoryID: String?
  @Published private(set) var progress: ModelDownloadProgress?
  @Published private(set) var currentFile = ""
  @Published private(set) var downloadedFolder: URL?
  @Published private(set) var error: String?
  @Published private(set) var isDownloading = false
  private var task: Task<Void, Never>?
  private let downloader: HuggingFaceFileDownloader

  init(downloader: HuggingFaceFileDownloader = HuggingFaceFileDownloader()) { self.downloader = downloader }

  func download(_ repository: HuggingFaceRepository, selected: Set<String>, into directory: URL) {
    guard !isDownloading else { return }
    repositoryID = repository.id
    downloadedFolder = nil
    error = nil
    currentFile = ""
    isDownloading = true
    progress = ModelDownloadProgress(receivedByteCount: 0,
      expectedByteCount: repository.siblings.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size })
    task = Task {
      let accessed = directory.startAccessingSecurityScopedResource()
      defer {
        if accessed { directory.stopAccessingSecurityScopedResource() }
        isDownloading = false
        task = nil
      }
      do {
        downloadedFolder = try await downloader.download(repository, selected: selected, into: directory) { [weak self] file, progress in
          await self?.update(file, progress: progress)
        }
      } catch {
        self.error = Task.isCancelled || error is CancellationError
          ? "Download cancelled. No incomplete model files were kept."
          : "Download failed: \(error.localizedDescription)"
      }
    }
  }

  private func update(_ file: String, progress: ModelDownloadProgress) {
    currentFile = file
    self.progress = progress
  }

  func cancel() { task?.cancel() }
}
