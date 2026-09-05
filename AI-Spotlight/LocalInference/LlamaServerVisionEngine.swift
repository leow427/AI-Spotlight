import Darwin
import Foundation

protocol LocalVisionServing: Sendable {
  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) -> AsyncThrowingStream<String, Error>
}

enum LocalVisionModelValidation {
  static func validate(_ model: LocalModel) throws {
    guard let config = model.visionConfiguration,
          (4096...32768).contains(config.contextWindow),
          model.fileURL.resolvingSymlinksInPath() != config.projectorURL.resolvingSymlinksInPath(),
          FileManager.default.isExecutableFile(atPath: config.serverExecutableURL.path) else {
      throw LocalInferenceError.bridgeFailure("Choose a local vision GGUF, its matching mmproj GGUF, and a current llama-server executable.")
    }
    for url in [model.fileURL, config.projectorURL] {
      guard url.isFileURL, url.pathExtension.lowercased() == "gguf" else { throw LocalInferenceError.invalidModelFile }
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      guard let header = try file.read(upToCount: 8), header.count == 8,
            Array(header.prefix(4)) == [0x47, 0x47, 0x55, 0x46],
            header[4] == 2 || header[4] == 3, header[5...7].allSatisfy({ $0 == 0 }) else {
        throw LocalInferenceError.invalidModelFile
      }
    }
  }
}

/// A dedicated, short-lived offline server keeps optional vision separate from the embedded text engine.
struct LlamaServerVisionEngine: LocalVisionServing {
  static func arguments(model: LocalModel, port: UInt16, key: String, alias: String) throws -> [String] {
    try LocalVisionModelValidation.validate(model)
    let config = model.visionConfiguration!
    return ["-m", model.fileURL.path, "--mmproj", config.projectorURL.path,
            "--host", "127.0.0.1", "--port", String(port), "--api-key", key, "--alias", alias,
            "--ctx-size", String(config.contextWindow), "--parallel", "1", "--offline", "--no-webui"]
  }

  static func prepare(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) throws -> PreparedConversation {
    guard model.supportsVision, let config = model.visionConfiguration else { throw ScreenRequestError.textOnlyModel }
    if let image { try ScreenRequestGuard.validateImage(image) }
    return try ChatContextPreparer.prepare(messages,
      budget: ContextBudget(contextWindow: config.contextWindow, outputTokens: 512, overheadTokens: 256),
      countTokens: { $0.reduce(image == nil ? 0 : 4096) { $0 + $1.content.utf8.count + 32 } })
  }

  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let process = Process()
      let task = Task {
        defer {
          // Never keep a vision model resident by accident. Only terminate this request's child.
          if process.isRunning {
            process.terminate()
            Task.detached {
              try? await Task.sleep(for: .seconds(2))
              if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
          }
        }
        do {
          let prepared = try Self.prepare(messages: messages, image: image, model: model)
          let port = try Self.availablePort()
          let key = UUID().uuidString
          let alias = "screen-" + UUID().uuidString
          process.executableURL = model.visionConfiguration?.serverExecutableURL
          process.arguments = try Self.arguments(model: model, port: port, key: key, alias: alias)
          // Exclude inherited llama download/router/proxy settings and disable network downloads.
          process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
          process.standardOutput = FileHandle.nullDevice
          process.standardError = FileHandle.nullDevice
          try Task.checkCancellation()
          try process.run()
          try Task.checkCancellation()
          let session = LocalOnlyNetworking.makeSession()
          defer { session.invalidateAndCancel() }
          let transport = URLSessionCloudTransport(session: session)
          let base = URL(string: "http://127.0.0.1:\(port)")!
          let deadline = ContinuousClock.now.advanced(by: .seconds(120))
          var ready = false
          while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else { throw LocalInferenceError.bridgeFailure("llama-server could not load the vision model. Check that the model and projector match and that llama-server is up to date.") }
            var check = URLRequest(url: base.appendingPathComponent("v1/models"), timeoutInterval: 1)
            check.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let response = try? await transport.data(for: check), response.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
               let entries = object["data"] as? [[String: Any]], entries.contains(where: { $0["id"] as? String == alias }) {
              ready = true
              break
            }
            try await Task.sleep(for: .milliseconds(150))
          }
          guard ready else { throw LocalInferenceError.bridgeFailure("The local vision model took too long to load. Try a smaller model or check the matching projector.") }
          let runtimeModel = ScreenModel(id: alias, provider: "llama.cpp", isLocal: true, capabilities: .textAndVision,
                                         visionProjectorPath: model.visionProjectorPath)
          let client = LocalMultimodalClient(endpoint: base.appendingPathComponent("v1/chat/completions"),
                                             api: .openAICompatible, transport: transport, apiKey: key)
          for try await text in client.stream(messages: prepared.messages, image: image, model: runtimeModel) {
            try Task.checkCancellation()
            continuation.yield(text)
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
        if process.isRunning { process.terminate() }
      }
    }
  }

  private static func availablePort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ScreenRequestError.invalidLocalEndpoint }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
    }
    guard bound == 0, named == 0 else { throw ScreenRequestError.invalidLocalEndpoint }
    return UInt16(bigEndian: address.sin_port)
  }
}

final class LocalOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

enum LocalOnlyNetworking {
  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [:]
    config.urlCache = nil
    config.httpCookieStorage = nil
    config.timeoutIntervalForRequest = 180
    config.timeoutIntervalForResource = 300
    return URLSession(configuration: config, delegate: LocalOnlyRedirectDelegate(), delegateQueue: nil)
  }
}

/// A pinned official runtime is installed beside the model library, including
/// its dynamic libraries. Nothing depends on a temporary folder or shell PATH.
struct LocalVisionRuntime: Sendable {
  let archive: VerifiedModelArtifact
  static let directoryName = "llama-b10797"

  static var bundled: LocalVisionRuntime {
    #if arch(arm64)
    let architecture = "arm64"
    let size: Int64 = 11108860
    let checksum = "474a788ec73d17a066360b1c50c9733c78a47d062616e91963c65a344548e889"
    #else
    let architecture = "x64"
    let size: Int64 = 11156383
    let checksum = "a12a85385c74e1e0260dd207cc49f90db902df0fa2f12fc734971d0323aa1df0"
    #endif
    return LocalVisionRuntime(archive: VerifiedModelArtifact(
      url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b10797/llama-b10797-bin-macos-\(architecture).tar.gz")!,
      expectedByteCount: size, checksumSHA256: checksum))
  }

  func validate() throws {
    try archive.validate()
    guard archive.url == Self.bundled.archive.url else {
      throw LocalModelCatalogError.invalidManifest("vision runtime")
    }
  }

  func install(archive: URL, staging: URL, destination: URL) async throws -> URL {
    let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
    let listing = try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tzf", archive.path], in: staging)
    let paths = listing.split(whereSeparator: \.isNewline).map(String.init)
    guard !paths.isEmpty, paths.allSatisfy({ path in
      (path == Self.directoryName || path.hasPrefix(Self.directoryName + "/"))
        && !path.split(separator: "/").contains("..")
    }) else { throw LocalInferenceError.bridgeFailure("The image support download contains invalid paths.") }
    _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"),
      ["-xzf", archive.path, "--no-same-owner", "-C", unpacked.path], in: staging)
    let root = unpacked.resolvingSymlinksInPath().path + "/"
    let entries = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)
    while let url = entries?.nextObject() as? URL {
      guard url.resolvingSymlinksInPath().path.hasPrefix(root) else {
        throw LocalInferenceError.bridgeFailure("The image support download contains an invalid link.")
      }
    }
    let relativeServer = Self.directoryName + "/llama-server"
    let server = unpacked.appending(path: relativeServer)
    guard FileManager.default.isExecutableFile(atPath: server.path) else {
      throw LocalInferenceError.bridgeFailure("The image support download is incomplete. Try downloading again.")
    }
    let help = try await Self.run(server, ["--help"], in: staging)
    guard help.contains("--mmproj"), help.contains("--offline") else {
      throw LocalInferenceError.bridgeFailure("The downloaded image support could not start on this Mac.")
    }
    try Task.checkCancellation()
    try FileManager.default.moveItem(at: unpacked, to: destination)
    return destination.appending(path: relativeServer)
  }

  private static func run(_ executable: URL, _ arguments: [String], in directory: URL) async throws -> String {
    let output = directory.appending(path: "runtime-output-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let file = try FileHandle(forWritingTo: output)
    defer { try? file.close(); try? FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
    process.standardOutput = file
    process.standardError = file
    let timeout = Task {
      try await Task.sleep(for: .seconds(30))
      if process.isRunning { process.terminate() }
    }
    defer { timeout.cancel() }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
          try process.run()
          if Task.isCancelled && process.isRunning { process.terminate() }
        } catch { continuation.resume(throwing: error) }
      }
      try Task.checkCancellation()
      guard process.terminationStatus == 0 else {
        throw LocalInferenceError.bridgeFailure("Image support could not be installed. Try downloading again.")
      }
    } onCancel: { if process.isRunning { process.terminate() } }
    return String(decoding: try Data(contentsOf: output), as: UTF8.self)
  }
}
