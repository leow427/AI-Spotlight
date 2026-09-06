import AppKit
import Darwin
import Foundation

protocol LocalVisionServing: Sendable {
  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) -> AsyncThrowingStream<String, Error>
  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel, temperature: Float) -> AsyncThrowingStream<String, Error>
  func unload() async
  func benchmark(model: LocalModel) async throws -> LocalBenchmarkMetrics?
}

extension LocalVisionServing {
  func unload() async { }
  func benchmark(model: LocalModel) async throws -> LocalBenchmarkMetrics? { nil }
  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel, temperature: Float) -> AsyncThrowingStream<String, Error> {
    stream(messages: messages, image: image, model: model)
  }
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

/// One resident main model serves text, images, planning and answers. The child
/// owns no conversation state: every call supplies the complete prepared messages.
actor LlamaServerVisionEngine: LocalVisionServing, LocalToolInference {
  private var runtime: LocalModelRuntimeSession?
  private var activeID: UUID?
  private var idleTask: Task<Void, Never>?
  private var idleID: UUID?
  private let idleDelay: Duration
  init(idleDelay: Duration = .seconds(300)) { self.idleDelay = idleDelay }

  func runtimeProcessIdentifier() -> Int32? {
    guard let runtime, runtime.process.isRunning else { return nil }
    return runtime.process.processIdentifier
  }

  func unload() async {
    idleTask?.cancel()
    idleTask = nil
    idleID = nil
    activeID = nil
    runtime?.close()
    runtime = nil
  }

  private func unloadIfIdle(id: UUID) async {
    guard activeID == nil, idleID == id else { return }
    await unload()
  }

  private func cancel(id: UUID) async {
    guard activeID == id else { return }
    await unload()
  }

  static func arguments(model: LocalModel, port: UInt16, key: String, alias: String) throws -> [String] {
    if !model.supportsVision { return try LocalFileRuntime.textArguments(model: model, port: port, key: key, alias: alias) }
    try LocalVisionModelValidation.validate(model)
    let config = model.visionConfiguration!
    return ["-m", model.fileURL.path, "--mmproj", config.projectorURL.path,
            "--host", "127.0.0.1", "--port", String(port), "--api-key", key, "--alias", alias,
            "--ctx-size", String(config.contextWindow), "--parallel", "1", "--offline", "--no-webui",
            "--jinja", "--no-context-shift", "--cache-ram", "0", "--reasoning-budget", "0",
            "--fit", "off", "--image-max-tokens", "4096"]
  }

  static func prepare(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) throws -> PreparedConversation {
    guard model.supportsVision, let config = model.visionConfiguration else { throw ScreenRequestError.textOnlyModel }
    if image != nil, model.id == "smolvlm-2b-q4:vision",
       config.packageRevision != "1bc3c9f74ceafd4c8d4411cc9cf188bba3798f91" {
      throw LocalInferenceError.bridgeFailure("This legacy SmolVLM package cannot process images with its runtime. Install and select a recommended model in Settings → Local Models. Your draft has been kept.")
    }
    if let image { try ScreenRequestGuard.validateImage(image) }
    return try ChatContextPreparer.prepare(messages,
      budget: ContextBudget(contextWindow: config.contextWindow, outputTokens: 512, overheadTokens: 256),
      countTokens: { $0.reduce(image == nil ? 0 : 4096) { $0 + $1.content.utf8.count + 32 } })
  }

  nonisolated func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) -> AsyncThrowingStream<String, Error> {
    stream(messages: messages, image: image, model: model, temperature: 0.7)
  }

  nonisolated func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel,
                          temperature: Float) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task { await self.generate(messages: messages, image: image, model: model,
                                            temperature: temperature, continuation: continuation) }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private func generate(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel,
                        temperature: Float, continuation: AsyncThrowingStream<String, Error>.Continuation) async {
    let id = UUID()
    // Replacing a cancelled consumer cannot race its cleanup into the new child.
    if activeID != nil { await unload() }
    idleTask?.cancel()
    idleID = nil
    activeID = id
    await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        let prepared = try Self.prepare(messages: messages, image: image, model: model)
        let session = try await load(model, requestID: id)
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
        let runtimeModel = ScreenModel(id: session.alias, provider: "llama.cpp", isLocal: true,
          capabilities: .textAndVision, visionProjectorPath: model.visionProjectorPath)
        let client = LocalMultimodalClient(endpoint: session.base.appendingPathComponent("v1/chat/completions"),
          api: .openAICompatible, transport: URLSessionCloudTransport(session: session.network), apiKey: session.key)
        for try await text in client.stream(messages: prepared.messages, image: image, model: runtimeModel,
                                            temperature: temperature) {
          try Task.checkCancellation()
          guard activeID == id else { throw CancellationError() }
          continuation.yield(text)
        }
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
        activeID = nil
        scheduleIdleUnload(id: id)
        continuation.finish()
      } catch {
        await cancel(id: id)
        continuation.finish(throwing: error)
      }
    } onCancel: { Task { await self.cancel(id: id) } }
  }

  func benchmark(model: LocalModel) async throws -> LocalBenchmarkMetrics? {
    let id = UUID()
    if activeID != nil { await unload() }
    idleTask?.cancel()
    idleID = nil
    activeID = id
    return try await withTaskCancellationHandler {
      do {
        let loadStart = ProcessInfo.processInfo.systemUptime
        let session = try await load(model, requestID: id)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        let probe = LocalRuntimeBenchmarkProbe()
        let pid = session.process.processIdentifier
        let sampler = Task.detached {
          while !Task.isCancelled {
            probe.sample(pid: pid)
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
          }
        }
        let deadline = Task { [weak self] in
          do {
            try await Task.sleep(for: .seconds(60))
            try Task.checkCancellation()
            await self?.cancel(id: id)
          } catch { }
        }
        defer { sampler.cancel(); deadline.cancel() }
        let prompt = "Write a detailed numbered list of twenty practical ways to organize a home office. Explain each suggestion in a full sentence, covering the desk, lighting, documents, cables, storage and daily routines."
        let runtimeModel = ScreenModel(id: session.alias, provider: "llama.cpp", isLocal: true,
          capabilities: .textAndVision, visionProjectorPath: model.visionProjectorPath)
        let client = LocalMultimodalClient(endpoint: session.base.appendingPathComponent("v1/chat/completions"),
          api: .openAICompatible, transport: URLSessionCloudTransport(session: session.network), apiKey: session.key)
        let start = ProcessInfo.processInfo.systemUptime
        var firstTokenSeconds: Double?
        for try await fragment in client.stream(messages: [ChatMessage(role: .user, content: prompt)], image: nil,
          model: runtimeModel, maximumTokens: 64, temperature: 0, timings: { probe.record($0) }) {
          try Task.checkCancellation()
          guard activeID == id else { throw CancellationError() }
          if !fragment.isEmpty && firstTokenSeconds == nil { firstTokenSeconds = ProcessInfo.processInfo.systemUptime - start }
        }
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
        probe.sample(pid: pid)
        let metrics = try probe.metrics(firstToken: firstTokenSeconds, loadSeconds: loadSeconds)
        activeID = nil
        scheduleIdleUnload(id: id)
        return metrics
      } catch {
        await cancel(id: id)
        throw error
      }
    } onCancel: { Task { await self.cancel(id: id) } }
  }

  /// llama.cpp's native function calling endpoint performs template rendering and structured parsing.
  /// The controller owns the tool loop; this method only performs one inference step.
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition],
                     model: LocalModel) async throws -> AgentInferenceMessage {
    let id = UUID()
    if activeID != nil { await unload() }
    idleTask?.cancel()
    idleID = nil
    activeID = id
    return try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        let session = try await load(model, requestID: id)
        let payload = try LocalFileRuntime.payload(messages: messages, tools: tools, alias: session.alias)
        // Render and tokenize the exact tool-aware template before inference. This avoids silently
        // truncating a tool result or dropping the user's request when the agent reaches its budget.
        let template = try await toolJSON(path: "apply-template", payload: payload, session: session)
        guard let prompt = template["prompt"].string else {
          throw FileModeError.operation("The local runtime did not return a rendered tool template.")
        }
        let tokens = try await toolJSON(path: "tokenize", payload: .object([
          "content": .string(prompt), "add_special": .bool(true)]), session: session)
        guard let count = tokens["tokens"].array?.count else {
          throw FileModeError.operation("The local runtime did not return a token count for this file task.")
        }
        guard count + 1_088 < LocalFileRuntime.contextWindow(for: model) else {
          throw FileModeError.operation("This file task filled the local model’s context. Start a new chat with a smaller selection or ask about a shorter section. Review keeps any completed edits.")
        }
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
        let response = try await toolJSON(path: "v1/chat/completions", payload: payload, session: session)
        let message = try LocalFileRuntime.response(JSONEncoder().encode(response))
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
        activeID = nil
        scheduleIdleUnload(id: id)
        return message
      } catch {
        await cancel(id: id)
        throw error
      }
    } onCancel: { Task { await self.cancel(id: id) } }
  }

  private func toolJSON(path: String, payload: CodexValue, session: LocalModelRuntimeSession) async throws -> CodexValue {
    var request = URLRequest(url: session.base.appendingPathComponent(path), timeoutInterval: 180)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(session.key)", forHTTPHeaderField: "Authorization")
    // Stable schema/property order keeps native chat templates consistent across launches.
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    request.httpBody = try encoder.encode(payload)
    guard request.httpBody!.count <= 2 * 1_024 * 1_024 else { throw FileModeError.tooLarge }
    let result = try await URLSessionCloudTransport(session: session.network).data(for: request)
    guard result.statusCode == 200 else {
      throw FileModeError.operation("This llama-server runtime could not complete structured file tools. Update its runtime or choose a recommended local model. File Mode never runs commands found in ordinary model text.")
    }
    guard result.data.count <= 4 * 1_024 * 1_024 else { throw FileModeError.tooLarge }
    return try JSONDecoder().decode(CodexValue.self, from: result.data)
  }

  private func scheduleIdleUnload(id: UUID) {
    idleID = id
    idleTask = Task { [weak self, idleDelay] in
      do {
        try await Task.sleep(for: idleDelay)
        try Task.checkCancellation()
        await self?.unloadIfIdle(id: id)
      } catch { }
    }
  }

  private func load(_ model: LocalModel, requestID: UUID) async throws -> LocalModelRuntimeSession {
    if let runtime, runtime.model == model, runtime.process.isRunning { return runtime }
    runtime?.close()
    runtime = nil
    if let descriptor = model.catalogDescriptor, descriptor.supportsVision {
      let hardware = LocalHardwareProfile.detect(modelsDirectory: model.fileURL.deletingLastPathComponent())
      let assessment = LocalModelSelector.assess(descriptor, hardware: hardware, installed: true)
      guard assessment.fit.canRun else { throw LocalInferenceError.bridgeFailure(assessment.reason) }
    }
    let port = try Self.availablePort()
    let session = LocalModelRuntimeSession(model: model, port: port)
    session.process.executableURL = LocalFileRuntime.executable(for: model)
    session.process.arguments = try Self.arguments(model: model, port: port, key: session.key, alias: session.alias)
    session.process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
    session.process.standardOutput = FileHandle.nullDevice
    session.process.standardError = FileHandle.nullDevice
    try Task.checkCancellation()
    try session.process.run()
    runtime = session
    let deadline = ContinuousClock.now.advanced(by: .seconds(180))
    let transport = URLSessionCloudTransport(session: session.network)
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard activeID == requestID else { throw CancellationError() }
      guard session.process.isRunning else {
        throw LocalInferenceError.bridgeFailure("The local model could not load. Reinstall its package in Local Models or choose a model that fits this Mac.")
      }
      if LocalOnlyNetworking.isListening(on: port) {
        var check = URLRequest(url: session.base.appendingPathComponent("health"), timeoutInterval: 1)
        check.setValue("Bearer \(session.key)", forHTTPHeaderField: "Authorization")
        if let response = try? await transport.data(for: check), response.statusCode == 200 {
          check.url = session.base.appendingPathComponent("v1/models")
          if let models = try? await transport.data(for: check), models.statusCode == 200,
             let object = try? JSONSerialization.jsonObject(with: models.data) as? [String: Any],
             let entries = object["data"] as? [[String: Any]],
             entries.contains(where: { $0["id"] as? String == session.alias }) {
            return session
          }
        }
      }
      try await Task.sleep(for: .milliseconds(150))
    }
    throw LocalInferenceError.bridgeFailure("The local model took too long to load. Choose a smaller recommended model. Your draft has been kept.")
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

/// Actual server token/timing counters and sampled combined resident memory.
/// RSS is deliberately conservative and may count shared library pages twice.
private final class LocalRuntimeBenchmarkProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var timings: [String: Double] = [:]
  private var peak: Int64 = 0
  func record(_ value: [String: Double]) { lock.withLock { timings = value } }
  func sample(pid: Int32) {
    let memory = Self.residentBytes(pid) + Self.residentBytes(getpid())
    lock.withLock { peak = max(peak, memory) }
  }
  func metrics(firstToken: Double?, loadSeconds: Double) throws -> LocalBenchmarkMetrics {
    try lock.withLock {
      guard let firstToken, let prompt = timings["prompt_n"], let predicted = timings["predicted_n"],
            let promptSpeed = timings["prompt_per_second"], let speed = timings["predicted_per_second"],
            prompt.isFinite, predicted.isFinite, prompt > 0, prompt <= 131_072, predicted >= 16, predicted <= 128 else {
        throw LocalInferenceError.bridgeFailure("The runtime did not return enough timing data. Retry Check Performance.")
      }
      let result = LocalBenchmarkMetrics(timeToFirstToken: firstToken, generationTokensPerSecond: speed,
        promptTokensPerSecond: promptSpeed, peakMemoryBytes: peak, promptTokenCount: Int(prompt),
        generatedTokenCount: Int(predicted), modelLoadSeconds: loadSeconds)
      guard result.isValid else { throw LocalInferenceError.bridgeFailure("The runtime returned invalid performance measurements.") }
      return result
    }
  }
  private static func residentBytes(_ pid: Int32) -> Int64 {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let read = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, size) }
    return read == size ? Int64(clamping: info.pti_resident_size) : 0
  }
}

private final class LocalModelRuntimeSession: @unchecked Sendable {
  let model: LocalModel
  let process = Process()
  let network = LocalOnlyNetworking.makeSession()
  let key = UUID().uuidString
  let alias = "local-" + UUID().uuidString
  let base: URL
  private var terminationObserver: NSObjectProtocol?
  init(model: LocalModel, port: UInt16) {
    self.model = model
    base = URL(string: "http://127.0.0.1:\(port)")!
    terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
      object: nil, queue: nil) { [process, network] _ in
        // Async actor cleanup is too late once AppKit is terminating. Kill only
        // this owned child so a large model cannot outlive the app.
        network.invalidateAndCancel()
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
      }
  }
  func close() {
    network.invalidateAndCancel()
    if process.isRunning {
      process.terminate()
      Task.detached { [process] in
        try? await Task.sleep(for: .seconds(2))
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
      }
    }
  }
  deinit {
    if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    close()
  }
}

final class LocalOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

enum LocalOnlyNetworking {
  static func isListening(on port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    // Even loopback connect can wait for TCP retries. Keep readiness polling
    // bounded so startup and cancellation cannot stall on a half-open listener.
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return false }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    guard Darwin.poll(&pending, 1, 50) > 0 else { return false }
    var socketError: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 && socketError == 0
  }

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
  static let build = 10797
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
