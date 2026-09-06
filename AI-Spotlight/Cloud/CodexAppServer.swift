import Foundation

enum CodexValue: Codable, Equatable, Sendable {
  case object([String: CodexValue])
  case array([CodexValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode([CodexValue].self) { self = .array(value) }
    else { self = .object(try container.decode([String: CodexValue].self)) }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  subscript(_ key: String) -> CodexValue {
    guard case .object(let value) = self else { return .null }
    return value[key] ?? .null
  }

  var string: String? { if case .string(let value) = self { value } else { nil } }
  var array: [CodexValue]? { if case .array(let value) = self { value } else { nil } }
  var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
  var integer: Int? {
    guard case .number(let value) = self else { return nil }
    return Int(exactly: value)
  }
}

struct CodexNotification: Sendable {
  let method: String
  let params: CodexValue
}

struct CodexNotificationSubscription: Sendable {
  let stream: AsyncThrowingStream<CodexNotification, Error>
  let cancel: @Sendable () async -> Void
}

enum CodexError: LocalizedError, Equatable {
  case notInstalled
  case notSignedIn
  case invalidResponse
  case fileModePreparationFailed(Int32)
  case disconnected
  case timedOut
  case browserUnavailable
  case server(String)

  var errorDescription: String? {
    switch self {
    case .notInstalled:
      "Install the Codex CLI, then reopen Settings. AI Spotlight uses its supported ChatGPT sign-in."
    case .notSignedIn:
      "Sign in with ChatGPT in Settings to use your plan's Codex allowance."
    case .invalidResponse:
      "AI Spotlight could not read the Codex response. Try again."
    case .fileModePreparationFailed(let status):
      "AI Spotlight could not prepare Codex File Mode (startup check exited with code \(status)). Restart AI Spotlight and try again."
    case .disconnected:
      "The Codex connection closed. Try again; if it persists, update the Codex CLI."
    case .timedOut:
      "Codex did not respond in time. Check your connection and try again."
    case .browserUnavailable:
      "The sign-in page could not be opened in your browser."
    case .server(let message): message
    }
  }
}

struct CodexRuntimeConfiguration: Sendable {
  static let live = CodexRuntimeConfiguration(
    directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight/Codex", directoryHint: .isDirectory)
  )

  static let fileMode = CodexRuntimeConfiguration(directory: live.directory, allowsFileTools: true)

  let directory: URL
  var allowsFileTools = false

  static func executableURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [environment["AI_SPOTLIGHT_CODEX_PATH"]].compactMap { $0 }
      + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
         "/Applications/Codex.app/Contents/Resources/codex",
         "/Applications/ChatGPT.app/Contents/Resources/codex"]
      + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
    return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
  }

  // A separate home keeps app logins, plugins, hooks, and preferences isolated from the user's CLI.
  var environment: [String: String] {
    [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "TMPDIR": FileManager.default.temporaryDirectory.path,
      "LANG": "en_US.UTF-8",
      "CODEX_HOME": directory.path,
    ]
  }

  var arguments: [String] {
    let overrides = [
      "forced_login_method=\"chatgpt\"", "cli_auth_credentials_store=\"keyring\"",
      "model_provider=\"openai\"", "history.persistence=\"none\"", "web_search=\"disabled\"",
      "features.shell_tool=false", "features.unified_exec=false", "features.shell_snapshot=false",
      "features.apps=false", "features.plugins=false", "features.remote_plugin=false",
      "features.hooks=false", "features.multi_agent=false", "features.browser_use=false",
      "features.computer_use=false", "features.image_generation=false", "features.view_image=false",
      "features.skill_search=false", "tools.view_image=false", "project_doc_max_bytes=0",
      "features.skip_host_skill_discovery=true", "features.workspace_dependencies=false",
      "features.code_mode=false", "features.code_mode_host=\(allowsFileTools)", "features.artifact=false",
      "features.memories=false", "features.tool_suggest=false", "features.goals=false",
    ]
    return ["app-server", "--listen", "stdio://"] + overrides.flatMap { ["-c", $0] }
  }
}

protocol CodexRPCTransport: Sendable {
  func request(_ method: String, params: CodexValue) async throws -> CodexValue
  func notifications() async throws -> CodexNotificationSubscription
  func prepareFileMode() async throws
  func setFileHandler(threadID: String, handler: CodexServerRequestHandler?) async throws
}

extension CodexRPCTransport {
  func prepareFileMode() async throws { throw FileModeError.operation("This Codex connection does not support File Mode.") }
  func setFileHandler(threadID: String, handler: CodexServerRequestHandler?) async throws {
    if handler != nil { throw FileModeError.inactive }
  }
}

actor CodexAppServer: CodexRPCTransport {
  static let shared = CodexAppServer()
  static let fileMode = CodexAppServer(configuration: .fileMode)

  private let configuration: CodexRuntimeConfiguration
  private let executable: @Sendable () -> URL?
  private let requestTimeout: Duration
  private var process: Process?
  private var input: FileHandle?
  private var readerTask: Task<Void, Never>?
  private var startupTask: Task<Void, Error>?
  private var startupID: UUID?
  private var generation = UUID()
  private var buffer = Data()
  private var nextID = 0
  private var fileHandlers: [String: CodexServerRequestHandler] = [:]
  private var fileCalls: [String: Task<CodexValue, Never>] = [:]
  private var fileModeVerified = false
  private var pending: [Int: CheckedContinuation<CodexValue, Error>] = [:]
  private var timeouts: [Int: Task<Void, Never>] = [:]
  private var observers: [UUID: AsyncThrowingStream<CodexNotification, Error>.Continuation] = [:]

  init(
    configuration: CodexRuntimeConfiguration = .live,
    executable: @escaping @Sendable () -> URL? = { CodexRuntimeConfiguration.executableURL() },
    requestTimeout: Duration = .seconds(60)
  ) {
    self.configuration = configuration
    self.executable = executable
    self.requestTimeout = requestTimeout
  }

  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    try await start()
    return try await sendRequest(method, params: params)
  }

  func notifications() async throws -> CodexNotificationSubscription {
    try await start()
    let id = UUID()
    let stream = AsyncThrowingStream<CodexNotification, Error> { continuation in
      observers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeObserver(id) }
      }
    }
    return CodexNotificationSubscription(stream: stream, cancel: { [weak self] in
      await self?.removeObserver(id)
    })
  }

  func prepareFileMode() async throws {
    if fileModeVerified { return }
    guard let executableURL = executable() else { throw CodexError.notInstalled }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-spotlight-schema-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["app-server", "generate-json-schema", "--out", directory.path, "--experimental"]
    // Match the app-server isolation. Xcode's injected libraries and the user's CLI
    // environment must not leak into this short-lived compatibility check.
    try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
    process.environment = configuration.environment
    process.currentDirectoryURL = directory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    do {
      while process.isRunning {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw CodexError.timedOut }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard process.terminationStatus == 0 else { throw CodexError.fileModePreparationFailed(process.terminationStatus) }
      try CodexFileModeSupport.validateSchema(at: directory)
      fileModeVerified = true
    } catch {
      if process.isRunning { process.terminate() }
      throw error
    }
  }

  func setFileHandler(threadID: String, handler: CodexServerRequestHandler?) {
    fileHandlers[threadID] = handler
    if handler == nil {
      for key in fileCalls.keys.filter({ $0.hasPrefix(threadID + ":") }) {
        fileCalls.removeValue(forKey: key)?.cancel()
      }
    }
  }

  private func receiveServerRequest(_ message: CodexValue, method: String) {
    let params = message["params"]
    let threadID = params["threadId"].string ?? ""
    guard let handler = fileHandlers[threadID] else {
      try? write(.object(["id": message["id"], "error": .object([
        "code": .number(-32601), "message": .string("Unsupported by AI Spotlight")])]))
      return
    }
    let generation = generation
    // Deduplicate native tool call IDs so a replay cannot apply an edit twice.
    let key = threadID + ":" + (params["callId"].string ?? UUID().uuidString)
    let task: Task<CodexValue, Never>
    if let existing = fileCalls[key] { task = existing }
    else {
      guard fileCalls.count < 256 else { close(with: FileModeError.tooLarge); return }
      task = Task { await handler(method, params) }
      fileCalls[key] = task
    }
    Task {
      let result = await task.value
      guard generation == self.generation else { return }
      try? write(.object(["id": message["id"], "result": result]))
    }
  }

  func disconnect() {
    close(with: CodexError.disconnected)
  }

  private func start() async throws {
    if let startupTask { return try await startupTask.value }
    let id = UUID()
    startupID = id
    let task = Task {
      try launch()
      _ = try await sendRequest("initialize", params: .object([
        "clientInfo": .object([
          "name": .string("ai_spotlight"), "title": .string("AI Spotlight"), "version": .string("1.0"),
        ]),
        "capabilities": .object(["experimentalApi": .bool(true)]),
      ]))
      try write(.object(["method": .string("initialized")]))
    }
    startupTask = task
    do { try await task.value }
    catch {
      if startupID == id { close(with: error) }
      throw error
    }
  }

  private func launch() throws {
    guard let executableURL = executable() else { throw CodexError.notInstalled }
    try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
    let workspace = configuration.directory.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = configuration.arguments
    process.environment = configuration.environment
    process.currentDirectoryURL = workspace
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    // The parent must not keep the child's pipe ends alive, or EOF is never delivered.
    try? inputPipe.fileHandleForReading.close()
    try? outputPipe.fileHandleForWriting.close()
    self.process = process
    input = inputPipe.fileHandleForWriting
    let currentGeneration = UUID()
    generation = currentGeneration
    let chunks = AsyncStream<Data> { continuation in
      outputPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty { continuation.finish() }
        else { continuation.yield(data) }
      }
      continuation.onTermination = { _ in
        outputPipe.fileHandleForReading.readabilityHandler = nil
      }
    }
    readerTask = Task { [weak self] in
      for await data in chunks {
        await self?.receive(data, generation: currentGeneration)
      }
      await self?.didReachEOF(generation: currentGeneration)
    }
  }

  private func sendRequest(_ method: String, params: CodexValue) async throws -> CodexValue {
    try Task.checkCancellation()
    nextID += 1
    let id = nextID
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        timeouts[id] = Task { [weak self, requestTimeout] in
          do {
            try await Task.sleep(for: requestTimeout)
            await self?.finish(id, result: .failure(CodexError.timedOut))
          } catch {}
        }
        do {
          try write(.object(["id": .number(Double(id)), "method": .string(method), "params": params]))
        } catch {
          finish(id, result: .failure(error))
        }
      }
    } onCancel: {
      Task { await self.finish(id, result: .failure(CancellationError())) }
    }
  }

  private func write(_ value: CodexValue) throws {
    guard let input, process?.isRunning == true else { throw CodexError.disconnected }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    var data = try encoder.encode(value)
    data.append(0x0a)
    try input.write(contentsOf: data)
  }

  private func receive(_ data: Data, generation: UUID) {
    guard generation == self.generation else { return }
    buffer.append(data)
    guard buffer.count <= 8 * 1_024 * 1_024 else {
      close(with: CodexError.invalidResponse)
      return
    }
    while let newline = buffer.firstIndex(of: 0x0a) {
      let line = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      guard !line.isEmpty else { continue }
      guard let message = try? JSONDecoder().decode(CodexValue.self, from: line) else {
        close(with: CodexError.invalidResponse)
        return
      }
      if let method = message["method"].string {
        if message["id"] != .null {
          receiveServerRequest(message, method: method)
        } else {
          let notification = CodexNotification(method: method, params: message["params"])
          for observer in observers.values { observer.yield(notification) }
        }
      } else if let id = message["id"].integer {
        if message["error"] != .null {
          finish(id, result: .failure(CodexError.server(message["error"]["message"].string ?? "Codex request failed.")))
        } else {
          finish(id, result: .success(message["result"]))
        }
      }
    }
  }

  private func finish(_ id: Int, result: Result<CodexValue, Error>) {
    timeouts.removeValue(forKey: id)?.cancel()
    pending.removeValue(forKey: id)?.resume(with: result)
  }

  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.finish() }

  private func didReachEOF(generation: UUID) {
    guard generation == self.generation else { return }
    close(with: CodexError.disconnected)
  }

  private func close(with error: Error) {
    generation = UUID()
    readerTask?.cancel()
    readerTask = nil
    try? input?.close()
    input = nil
    if process?.isRunning == true { process?.terminate() }
    process = nil
    startupTask = nil
    startupID = nil
    buffer.removeAll()
    for id in Array(pending.keys) { finish(id, result: .failure(error)) }
    for observer in observers.values { observer.finish(throwing: error) }
    observers.removeAll()
    fileHandlers.removeAll()
    for task in fileCalls.values { task.cancel() }
    fileCalls.removeAll()
  }
}
