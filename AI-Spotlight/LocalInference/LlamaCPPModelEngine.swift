import Foundation
import LlamaBridge

actor LlamaCPPModelEngine: LocalModelEngine {
  private let installationStore: LocalModelInstallationStore
  private let catalog: LocalModelCatalog
  private let contextSize: Int32
  private var engineHandle: AISLlamaEngineHandle?
  private var loadedModelURL: URL?

  init(
    installationStore: LocalModelInstallationStore = LocalModelInstallationStore(),
    contextSize: Int32 = Int32(ModelContextPolicy.localContextWindow)
  ) {
    self.installationStore = installationStore
    catalog = LocalModelCatalog(installationStore: installationStore)
    self.contextSize = contextSize
  }

  func install(_ model: LocalModel) async throws {
    releaseEngine()
    _ = try installationStore.install(model)
  }

  func installedModel() async -> LocalModel? {
    installationStore.installedModel()
  }

  func installedModels() async -> [LocalModel] {
    installationStore.installedModels()
  }

  func selectModel(id: String) async throws {
    try installationStore.selectModel(id: id)
    releaseEngine()
  }

  func download(
    _ model: LocalModelDescriptor,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel {
    releaseEngine()
    return try await catalog.download(model, progress: progress)
  }

  func prepare(_ request: LocalModelRequest) async throws -> PreparedConversation {
    try Task.checkCancellation()
    let handle = try loadEngineIfNeeded()
    return try ChatContextPreparer.prepare(
      request.messages,
      budget: ContextBudget(contextWindow: Int(AISLlamaEngineContextSize(handle)),
                            outputTokens: request.maximumTokenCount, overheadTokens: 1),
      countTokens: { messages in
        try Task.checkCancellation()
        let count = try LocalChatBridge.withMessages(messages) { pointer, count in
          AISLlamaEngineCountChatTokens(handle, pointer, count)
        }
        guard count > 0 else { throw bridgeError() }
        return Int(count)
      }
    )
  }

  nonisolated func stream(
    _ request: LocalModelRequest
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await self.generate(request, continuation: continuation)
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  func unload() async {
    releaseEngine()
  }

  func benchmark() async throws -> LocalBenchmarkMetrics? {
    try Task.checkCancellation()
    releaseEngine()
    defer { releaseEngine() }
    let clock = { ProcessInfo.processInfo.systemUptime }
    let loadStart = clock()
    let handle = try loadEngineIfNeeded()
    let loadSeconds = clock() - loadStart
    // Version 1: fixed public prompt, greedy decoding, up to 64 output tokens.
    // No user conversation is used, saved, or transmitted.
    let request = LocalModelRequest(prompt: """
      Write a detailed numbered list of twenty practical ways to organize a home office.
      Explain each suggestion in one full sentence. Cover the desk, chair, lighting,
      documents, cables, storage, daily routines, and keeping the workspace tidy.
      Continue until you have explained all twenty suggestions. Start with item one.
      Here is the office: a small room with one window, a desk, a laptop, two monitors,
      a bookshelf, a printer, several notebooks, and a collection of charging cables.
      The room is used for reading, writing, video meetings, and planning projects.
      The owner wants a quiet, comfortable place to focus and an easy cleanup routine.
      """, maximumTokenCount: 64, temperature: 0)
    let promptTokens = try LocalChatBridge.withMessages(request.messages) {
      AISLlamaEngineCountChatTokens(handle, $0, $1)
    }
    guard promptTokens > 0 else { throw bridgeError() }
    var peak = AISLlamaProcessMemoryBytes()
    let start = clock()
    try beginCompletion(request, with: handle)
    let promptSeconds = clock() - start
    peak = max(peak, AISLlamaProcessMemoryBytes())
    var generationSeconds = 0.0
    var firstTokenSeconds = 0.0
    var count = 0
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while count < 64 {
      try Task.checkCancellation()
      guard clock() - start < 60 else {
        throw LocalInferenceError.bridgeFailure("The performance check took too long. You can retry it in Settings.")
      }
      var byteCount: Int32 = 0
      let tokenStart = clock()
      let result = buffer.withUnsafeMutableBufferPointer {
        AISLlamaEngineNextToken(handle, $0.baseAddress, Int32($0.count), &byteCount)
      }
      let tokenSeconds = clock() - tokenStart
      if result < 0 { throw bridgeError() }
      if result == 0 { break }
      count += 1
      generationSeconds += tokenSeconds
      if count == 1 { firstTokenSeconds = clock() - start }
      peak = max(peak, AISLlamaProcessMemoryBytes())
    }
    let metrics = LocalBenchmarkMetrics(
      timeToFirstToken: firstTokenSeconds,
      generationTokensPerSecond: Double(count) / max(0.000_001, generationSeconds),
      promptTokensPerSecond: Double(promptTokens) / max(0.000_001, promptSeconds),
      peakMemoryBytes: Int64(clamping: peak), promptTokenCount: Int(promptTokens),
      generatedTokenCount: count, modelLoadSeconds: loadSeconds
    )
    guard metrics.isValid else {
      throw LocalInferenceError.bridgeFailure("The model returned too few tokens to measure reliably. You can retry in Settings.")
    }
    return metrics
  }

  private func generate(
    _ request: LocalModelRequest,
    continuation: AsyncThrowingStream<String, Error>.Continuation
  ) {
    do {
      try Task.checkCancellation()
      let handle = try loadEngineIfNeeded()
      try beginCompletion(request, with: handle)

      var pendingBytes = Data()
      var tokenBuffer = [UInt8](repeating: 0, count: 4_096)
      while true {
        try Task.checkCancellation()
        var byteCount: Int32 = 0
        let result = tokenBuffer.withUnsafeMutableBufferPointer { buffer in
          AISLlamaEngineNextToken(
            handle,
            buffer.baseAddress,
            Int32(buffer.count),
            &byteCount
          )
        }

        if result < 0 {
          throw bridgeError()
        }
        if result == 0 {
          if !pendingBytes.isEmpty {
            continuation.yield(String(decoding: pendingBytes, as: UTF8.self))
          }
          continuation.finish()
          return
        }

        pendingBytes.append(contentsOf: tokenBuffer.prefix(Int(byteCount)))
        if let fragment = String(data: pendingBytes, encoding: .utf8) {
          pendingBytes.removeAll(keepingCapacity: true)
          if !fragment.isEmpty {
            continuation.yield(fragment)
          }
        }
      }
    } catch {
      continuation.finish(throwing: error)
    }
  }

  private func loadEngineIfNeeded() throws -> AISLlamaEngineHandle {
    guard let installedModel = installationStore.installedModel() else {
      throw LocalInferenceError.noModelInstalled
    }
    guard !installedModel.supportsVision else {
      throw LocalInferenceError.bridgeFailure("This vision profile uses llama-server instead of the embedded text engine.")
    }
    if let engineHandle, loadedModelURL == installedModel.fileURL {
      return engineHandle
    }

    releaseEngine()
    var requestedContext = contextSize
    if let descriptor = installedModel.catalogDescriptor {
      let hardware = LocalHardwareProfile.detect(modelsDirectory: installationStore.modelsDirectoryURL)
      let assessment = LocalModelSelector.assess(descriptor, hardware: hardware, installed: true)
      guard assessment.fit.canRun else { throw LocalInferenceError.bridgeFailure(assessment.reason) }
      requestedContext = Int32(descriptor.recommendedContextSize)
    }
    let newHandle = installedModel.fileURL.path.withCString { path in
      AISLlamaEngineCreate(path, requestedContext)
    }
    guard let newHandle else {
      throw bridgeError()
    }

    engineHandle = newHandle
    loadedModelURL = installedModel.fileURL
    return newHandle
  }

  private func beginCompletion(
    _ request: LocalModelRequest,
    with handle: AISLlamaEngineHandle
  ) throws {
    let didBegin = try LocalChatBridge.withMessages(request.messages) { messages, count in
      AISLlamaEngineBeginCompletion(
        handle,
        messages,
        count,
        Int32(clamping: request.maximumTokenCount),
        request.temperature
      )
    }
    guard didBegin else {
      throw bridgeError()
    }
  }

  private func bridgeError() -> LocalInferenceError {
    guard let errorMessage = AISLlamaBridgeLastError() else {
      return .bridgeFailure("llama.cpp encountered an unknown error.")
    }
    return .bridgeFailure(String(cString: errorMessage))
  }

  private func releaseEngine() {
    if let engineHandle {
      AISLlamaEngineDestroy(engineHandle)
    }
    engineHandle = nil
    loadedModelURL = nil
  }
}

/// Owns all C strings for the duration of a bridge call. No conversation state is
/// retained here or in the native KV cache between completion requests.
enum LocalChatBridge {
  static func formatted(_ messages: [ChatMessage], template: String) throws -> String {
    try withMessages(messages) { pointer, count in
      try template.withCString { template in
        let length = AISLlamaFormatChat(template, pointer, count, nil, 0)
        guard length > 0 else {
          throw LocalInferenceError.bridgeFailure(String(cString: AISLlamaBridgeLastError()))
        }
        var buffer = [CChar](repeating: 0, count: Int(length) + 1)
        let written = AISLlamaFormatChat(template, pointer, count, &buffer, Int32(buffer.count))
        guard written == length else {
          throw LocalInferenceError.bridgeFailure("The local chat template could not be formatted.")
        }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
      }
    }
  }

  static func withMessages<T>(
    _ messages: [ChatMessage],
    _ body: (UnsafePointer<AISLlamaChatMessage>?, Int32) throws -> T
  ) throws -> T {
    guard messages.count <= Int(Int32.max),
          !messages.contains(where: { $0.content.utf8.contains(0) }) else {
      throw ChatContextError.invalidText
    }
    let roles = messages.map { Array($0.role.rawValue.utf8CString) }
    let contents = messages.map { Array($0.content.utf8CString) }
    var allocations: [UnsafeMutablePointer<CChar>] = []
    defer { allocations.forEach { $0.deallocate() } }
    func copy(_ bytes: [CChar]) -> UnsafePointer<CChar> {
      let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
      pointer.initialize(from: bytes, count: bytes.count)
      allocations.append(pointer)
      return UnsafePointer(pointer)
    }
    let native = zip(roles, contents).map {
      AISLlamaChatMessage(role: copy($0), content: copy($1))
    }
    return try native.withUnsafeBufferPointer { try body($0.baseAddress, Int32($0.count)) }
  }
}
