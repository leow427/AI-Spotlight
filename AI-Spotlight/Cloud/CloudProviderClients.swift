import Foundation

struct CloudProviderRegistry: Sendable {
  static let live = CloudProviderRegistry(
    credentialStore: KeychainCredentialStore(),
    transport: URLSessionCloudTransport.shared
  )

  let openAI: any ChatProvider
  let anthropic: any ChatProvider

  init(
    credentialStore: any CloudCredentialStore,
    transport: any CloudNetworkTransport
  ) {
    openAI = OpenAIResponsesClient(
      credentialStore: credentialStore,
      transport: transport
    )
    anthropic = AnthropicMessagesClient(
      credentialStore: credentialStore,
      transport: transport
    )
  }

  func provider(for id: CloudProviderID) -> any ChatProvider {
    switch id {
    case .openAI: openAI
    case .anthropic: anthropic
    }
  }
}

struct OpenAIResponsesClient: ChatProvider {
  private let credentialStore: any CloudCredentialStore
  private let transport: any CloudNetworkTransport
  private let responsesURL: URL

  init(
    credentialStore: any CloudCredentialStore,
    transport: any CloudNetworkTransport,
    responsesURL: URL = URL(string: "https://api.openai.com/v1/responses")!
  ) {
    self.credentialStore = credentialStore
    self.transport = transport
    self.responsesURL = responsesURL
  }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try makeRequest(for: request)
          try await consume(urlRequest, continuation: continuation)
        } catch {
          continuation.finish(throwing: normalizedCloudError(error))
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private func makeRequest(for request: ChatRequest) throws -> URLRequest {
    guard request.route.providerID == CloudProviderID.openAI.rawValue else {
      throw CloudProviderError.invalidResponse
    }
    guard let apiKey = try credentialStore.apiKey(for: .openAI), !apiKey.isEmpty else {
      throw CloudProviderError.missingAPIKey(.openAI)
    }

    struct InputMessage: Encodable {
      let role: String
      let content: String
    }
    struct Body: Encodable {
      let model: String
      let input: [InputMessage]
      let stream: Bool
      let store: Bool
    }

    let body = Body(
      model: request.route.modelID,
      input: request.messages
        .filter { !$0.content.isEmpty }
        .map { InputMessage(role: $0.role.rawValue, content: $0.content) },
      stream: true,
      store: false
    )
    var urlRequest = URLRequest(url: responsesURL)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.httpBody = try JSONEncoder().encode(body)
    return urlRequest
  }

  private func consume(
    _ request: URLRequest,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) async throws {
    var parser = ServerSentEventParser()
    var statusCode: Int?
    var errorBody = Data()
    var didComplete = false

    for try await networkEvent in transport.stream(for: request) {
      try Task.checkCancellation()
      switch networkEvent {
      case .response(let responseStatusCode):
        statusCode = responseStatusCode
      case .data(let data):
        guard let statusCode else { throw CloudProviderError.invalidResponse }
        guard (200...299).contains(statusCode) else {
          errorBody.append(data)
          continue
        }
        for event in parser.append(data) {
          didComplete = try handle(event, continuation: continuation) || didComplete
        }
      }
    }

    guard let statusCode else { throw CloudProviderError.invalidResponse }
    guard (200...299).contains(statusCode) else {
      throw cloudHTTPError(provider: .openAI, statusCode: statusCode, data: errorBody)
    }
    for event in parser.finish() {
      didComplete = try handle(event, continuation: continuation) || didComplete
    }
    guard didComplete else { throw CloudProviderError.streamEndedUnexpectedly }
    continuation.finish()
  }

  private func handle(
    _ event: ServerSentEvent,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) throws -> Bool {
    if event.data == "[DONE]" {
      continuation.yield(.completed)
      return true
    }
    guard let data = event.data.data(using: .utf8),
          let payload = try? JSONDecoder().decode(OpenAIStreamPayload.self, from: data) else {
      throw CloudProviderError.invalidResponse
    }
    switch payload.type {
    case "response.output_text.delta":
      if let delta = payload.delta, !delta.isEmpty {
        continuation.yield(.token(delta))
      }
    case "response.completed":
      continuation.yield(.completed)
      return true
    case "response.failed", "response.incomplete", "error":
      throw CloudProviderError.providerMessage(
        payload.error?.message ?? payload.response?.error?.message
          ?? "OpenAI could not complete the response."
      )
    default:
      break
    }
    return false
  }
}

private struct OpenAIStreamPayload: Decodable {
  struct ErrorPayload: Decodable {
    let message: String
  }

  struct ResponsePayload: Decodable {
    let error: ErrorPayload?
  }

  let type: String
  let delta: String?
  let error: ErrorPayload?
  let response: ResponsePayload?
}

struct AnthropicMessagesClient: ChatProvider {
  private let credentialStore: any CloudCredentialStore
  private let transport: any CloudNetworkTransport
  private let messagesURL: URL

  init(
    credentialStore: any CloudCredentialStore,
    transport: any CloudNetworkTransport,
    messagesURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!
  ) {
    self.credentialStore = credentialStore
    self.transport = transport
    self.messagesURL = messagesURL
  }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try makeRequest(for: request)
          try await consume(urlRequest, continuation: continuation)
        } catch {
          continuation.finish(throwing: normalizedCloudError(error))
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private func makeRequest(for request: ChatRequest) throws -> URLRequest {
    guard request.route.providerID == CloudProviderID.anthropic.rawValue else {
      throw CloudProviderError.invalidResponse
    }
    guard let apiKey = try credentialStore.apiKey(for: .anthropic), !apiKey.isEmpty else {
      throw CloudProviderError.missingAPIKey(.anthropic)
    }

    struct InputMessage: Encodable {
      let role: String
      let content: String
    }
    struct Body: Encodable {
      let model: String
      let maxTokens: Int
      let messages: [InputMessage]
      let stream: Bool

      enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case maxTokens = "max_tokens"
      }
    }

    let body = Body(
      model: request.route.modelID,
      maxTokens: 4_096,
      messages: request.messages
        .filter { !$0.content.isEmpty }
        .map { InputMessage(role: $0.role.rawValue, content: $0.content) },
      stream: true
    )
    var urlRequest = URLRequest(url: messagesURL)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    urlRequest.httpBody = try JSONEncoder().encode(body)
    return urlRequest
  }

  private func consume(
    _ request: URLRequest,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) async throws {
    var parser = ServerSentEventParser()
    var statusCode: Int?
    var errorBody = Data()
    var didComplete = false

    for try await networkEvent in transport.stream(for: request) {
      try Task.checkCancellation()
      switch networkEvent {
      case .response(let responseStatusCode):
        statusCode = responseStatusCode
      case .data(let data):
        guard let statusCode else { throw CloudProviderError.invalidResponse }
        guard (200...299).contains(statusCode) else {
          errorBody.append(data)
          continue
        }
        for event in parser.append(data) {
          didComplete = try handle(event, continuation: continuation) || didComplete
        }
      }
    }

    guard let statusCode else { throw CloudProviderError.invalidResponse }
    guard (200...299).contains(statusCode) else {
      throw cloudHTTPError(provider: .anthropic, statusCode: statusCode, data: errorBody)
    }
    for event in parser.finish() {
      didComplete = try handle(event, continuation: continuation) || didComplete
    }
    guard didComplete else { throw CloudProviderError.streamEndedUnexpectedly }
    continuation.finish()
  }

  private func handle(
    _ event: ServerSentEvent,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) throws -> Bool {
    guard let data = event.data.data(using: .utf8),
          let payload = try? JSONDecoder().decode(AnthropicStreamPayload.self, from: data) else {
      throw CloudProviderError.invalidResponse
    }
    switch payload.type {
    case "content_block_delta" where payload.delta?.type == "text_delta":
      if let text = payload.delta?.text, !text.isEmpty {
        continuation.yield(.token(text))
      }
    case "message_stop":
      continuation.yield(.completed)
      return true
    case "error":
      throw CloudProviderError.providerMessage(
        payload.error?.message ?? "Anthropic could not complete the response."
      )
    default:
      break
    }
    return false
  }
}

private struct AnthropicStreamPayload: Decodable {
  struct Delta: Decodable {
    let type: String?
    let text: String?
  }

  struct ErrorPayload: Decodable {
    let message: String
  }

  let type: String
  let delta: Delta?
  let error: ErrorPayload?
}
