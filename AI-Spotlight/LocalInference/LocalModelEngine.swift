import Foundation

struct LocalModel: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let displayName: String
  let fileURL: URL
}

struct LocalModelRequest: Sendable, Equatable {
  let prompt: String
  let maximumTokenCount: Int
  let temperature: Float

  init(
    prompt: String,
    maximumTokenCount: Int = 512,
    temperature: Float = 0.7
  ) {
    self.prompt = prompt
    self.maximumTokenCount = maximumTokenCount
    self.temperature = temperature
  }
}

protocol LocalModelEngine: Sendable {
  func install(_ model: LocalModel) async throws
  func installedModel() async -> LocalModel?
  func installedModels() async -> [LocalModel]
  func selectModel(id: String) async throws
  func download(
    _ model: LocalModelDescriptor,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel
  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error>
  func unload() async
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
