import Foundation

struct LocalModel: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let displayName: String
  let fileURL: URL
  var catalogDescriptor: LocalModelDescriptor? = nil
  var visionConfiguration: LocalVisionConfiguration? = nil
}

struct LocalModelRequest: Sendable, Equatable {
  let messages: [ChatMessage]

  var prompt: String { messages.last?.content ?? "" }
  let maximumTokenCount: Int
  let temperature: Float

  init(
    prompt: String,
    maximumTokenCount: Int = ModelContextPolicy.localOutputTokens,
    temperature: Float = 0.7
  ) {
    self.init(messages: [ChatMessage(role: .user, content: prompt)],
              maximumTokenCount: maximumTokenCount, temperature: temperature)
  }

  init(
    messages: [ChatMessage],
    maximumTokenCount: Int = ModelContextPolicy.localOutputTokens,
    temperature: Float = 0.7
  ) {
    self.messages = messages
    self.maximumTokenCount = ThinkCommand.enabled(in: messages) ? max(maximumTokenCount, 2_048) : maximumTokenCount
    self.temperature = temperature
  }
}

protocol LocalModelEngine: Sendable {
  func install(_ model: LocalModel) async throws
  func installedModel() async -> LocalModel?
  func installedModels() async -> [LocalModel]
  func selectModel(id: String) async throws
  func deleteModel(id: String) async throws
  func download(
    _ model: LocalModelDescriptor,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel
  func prepare(_ request: LocalModelRequest) async throws -> PreparedConversation
  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error>
  func unload() async
  func benchmark() async throws -> LocalBenchmarkMetrics?
}

enum LocalInferenceError: LocalizedError, Equatable {
  case noModelInstalled
  case invalidModelFile
  case unknownInstalledModel
  case bridgeFailure(String)

  var errorDescription: String? {
    switch self {
    case .noModelInstalled:
      "Choose a GGUF model before using Local mode."
    case .invalidModelFile:
      "The selected file is not a readable GGUF model."
    case .unknownInstalledModel:
      "That local model is no longer installed."
    case .bridgeFailure(let message):
      message
    }
  }
}

extension LocalModelEngine {
  func deleteModel(id: String) async throws {
    throw LocalInferenceError.bridgeFailure("This model cannot be deleted by the current local engine.")
  }

  func benchmark() async throws -> LocalBenchmarkMetrics? { nil }

  func prepare(_ request: LocalModelRequest) async throws -> PreparedConversation {
    try ChatContextPreparer.prepare(
      request.messages,
      budget: ContextBudget(contextWindow: ModelContextPolicy.localContextWindow,
                            outputTokens: request.maximumTokenCount, overheadTokens: 256),
      countTokens: { $0.reduce(0) { $0 + $1.content.utf8.count + 32 } }
    )
  }
}
