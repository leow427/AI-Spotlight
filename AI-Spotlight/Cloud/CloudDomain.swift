import Foundation

enum CodexThinkingCapacity: String, CaseIterable, Identifiable, Sendable {
  case none
  case minimal
  case low
  case medium
  case high
  case xhigh
  case max
  case ultra

  var forExtendedThinking: Self {
    switch self {
    case .none, .minimal, .low, .medium, .high: .xhigh
    case .xhigh, .max, .ultra: self
    }
  }

  var id: Self { self }

  var displayName: String {
    switch self {
    case .none: "None"
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    case .max: "Max"
    case .ultra: "Ultra"
    }
  }
}

enum CloudProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
  case chatGPT = "chatgpt-codex"
  case openAI = "openai"
  case anthropic
  case gemini

  var id: Self { self }

  var displayName: String {
    switch self {
    case .chatGPT: "ChatGPT via Codex"
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .gemini: "Gemini"
    }
  }
}

struct CloudModel: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let displayName: String
  let provider: CloudProviderID
}

enum CloudProviderError: LocalizedError, Equatable, Sendable {
  case missingAPIKey(CloudProviderID)
  case unsupportedModel(CloudProviderID, modelID: String)
  case offline
  case authenticationFailed(CloudProviderID)
  case rateLimited(CloudProviderID)
  case invalidResponse
  case requestFailed(statusCode: Int, message: String?)
  case streamEndedUnexpectedly
  case providerMessage(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey(let provider):
      "Add an API key for \(provider.displayName) in Advanced Settings."
    case .unsupportedModel(let provider, let modelID):
      "\(modelID) cannot be used for text chat with \(provider.displayName) in AI Spotlight. Choose a compatible model in Advanced Settings."
    case .offline:
      "The cloud provider could not be reached. Check your internet connection."
    case .authenticationFailed(let provider):
      "\(provider.displayName) rejected the API key. Check it in Advanced Settings."
    case .rateLimited(let provider):
      "\(provider.displayName) is rate limiting this account. Please try again shortly."
    case .invalidResponse:
      "The cloud provider returned an invalid response."
    case .requestFailed(let statusCode, let message):
      message.map { "Cloud request failed (\(statusCode)): \($0)" }
        ?? "Cloud request failed with status \(statusCode)."
    case .streamEndedUnexpectedly:
      "The cloud response ended before it completed."
    case .providerMessage(let message):
      message
    }
  }
}

protocol CloudCredentialStore: Sendable {
  func containsAPIKey(for provider: CloudProviderID) throws -> Bool
  func apiKey(for provider: CloudProviderID) throws -> String?
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws
  func removeAPIKey(for provider: CloudProviderID) throws
}

extension CloudCredentialStore {
  func containsAPIKey(for provider: CloudProviderID) throws -> Bool {
    try apiKey(for: provider)?.isEmpty == false
  }
}

enum CloudNetworkEvent: Sendable, Equatable {
  case response(statusCode: Int)
  case data(Data)
}

struct CloudDataResponse: Sendable, Equatable {
  let data: Data
  let statusCode: Int
}

protocol CloudNetworkTransport: Sendable {
  func data(for request: URLRequest) async throws -> CloudDataResponse
  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error>
}

func normalizedCloudError(_ error: Error) -> Error {
  if error is CancellationError {
    return CancellationError()
  }
  guard let urlError = error as? URLError else { return error }
  switch urlError.code {
  case .cancelled:
    return CancellationError()
  case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
       .cannotFindHost, .dnsLookupFailed, .timedOut:
    return CloudProviderError.offline
  default:
    return error
  }
}

func cloudHTTPError(
  provider: CloudProviderID,
  statusCode: Int,
  data: Data
) -> CloudProviderError {
  switch statusCode {
  case 401, 403:
    return .authenticationFailed(provider)
  case 429:
    return .rateLimited(provider)
  default:
    return .requestFailed(
      statusCode: statusCode,
      message: providerErrorMessage(in: data)
    )
  }
}

private func providerErrorMessage(in data: Data) -> String? {
  guard !data.isEmpty,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    return nil
  }
  if let error = object["error"] as? [String: Any],
     let message = error["message"] as? String {
    return message
  }
  return object["message"] as? String
}
