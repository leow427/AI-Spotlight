import Foundation

/// Both native Ollama and llama-server use the same neutral message/image input.
struct LocalMultimodalClient: Sendable {
  enum API: Sendable { case openAICompatible, ollama }
  let endpoint: URL
  let api: API
  let transport: any CloudNetworkTransport
  var apiKey: String? = nil

  func makeRequest(messages: [ChatMessage], image: PreparedScreenImage?, model: ScreenModel, maximumTokens: Int = 512, temperature: Float = 0.7) throws -> URLRequest {
    guard ["127.0.0.1", "::1", "[::1]"].contains(endpoint.host ?? ""), endpoint.scheme == "http",
          endpoint.user == nil, endpoint.password == nil, model.isLocal else { throw ScreenRequestError.invalidLocalEndpoint }
    if image != nil && !model.canUseVision { throw ScreenRequestError.textOnlyModel }
    let format: MultimodalSerialization.Format = api == .ollama ? .ollama : .openAIChat
    var body: [String: Any] = ["model": model.id, "messages": [["role": "system", "content": ChatResponseStyle.instructions]] + (try MultimodalSerialization.messages(messages, image: image, format: format)), "stream": true]
    if api == .ollama {
      body["options"] = ["num_predict": maximumTokens, "temperature": temperature]
      body["think"] = ThinkCommand.enabled(in: messages)
    }
    else {
      body["max_tokens"] = maximumTokens
      body["temperature"] = temperature
      body["cache_prompt"] = false
      body["stream_options"] = ["include_usage": true]
      body["chat_template_kwargs"] = ["enable_thinking": ThinkCommand.enabled(in: messages)]
      body["reasoning_budget"] = ThinkCommand.enabled(in: messages) ? 1_024 : 0
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: ScreenModel, maximumTokens: Int = 512, temperature: Float = 0.7, timings: (@Sendable ([String: Double]) -> Void)? = nil) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try makeRequest(messages: messages, image: image, model: model, maximumTokens: maximumTokens, temperature: temperature)
          var parser = ServerSentEventParser()
          var lineBuffer = Data()
          var status: Int?
          var complete = false
          func consume(_ data: Data) throws {
            if String(data: data, encoding: .utf8) == "[DONE]" { complete = true; return }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudProviderError.invalidResponse }
            if let values = object["timings"] as? [String: Any] { timings?(values.compactMapValues { ($0 as? NSNumber)?.doubleValue }) }
            if object["error"] != nil { throw LocalInferenceError.bridgeFailure("The local model could not process the screenshot. Check the model and matching projector.") }
            if api == .ollama {
              if let message = object["message"] as? [String: Any], let text = message["content"] as? String { continuation.yield(text) }
              if object["done"] as? Bool == true { complete = true }
            } else if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
              if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String { continuation.yield(text) }
              if let reason = choice["finish_reason"] as? String, reason == "stop" || reason == "length" { complete = true }
            }
          }
          for try await event in transport.stream(for: request) {
            if Task.isCancelled { continue }
            switch event {
            case .response(let code): status = code
            case .data(let data):
              guard status == 200 else { throw LocalInferenceError.bridgeFailure("The local model returned an error. Verify the model and projector match.") }
              if api == .openAICompatible {
                for event in parser.append(data) { try consume(Data(event.data.utf8)) }
              } else {
                lineBuffer.append(data)
                while let newline = lineBuffer.firstIndex(of: 10) {
                  let line = Data(lineBuffer[..<newline])
                  lineBuffer.removeSubrange(...newline)
                  if !line.isEmpty { try consume(line) }
                }
              }
            }
          }
          try Task.checkCancellation()
          if api == .openAICompatible {
            for event in parser.finish() { try consume(Data(event.data.utf8)) }
          } else if !lineBuffer.isEmpty { try consume(lineBuffer) }
          guard complete else { throw CloudProviderError.streamEndedUnexpectedly }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }
}
