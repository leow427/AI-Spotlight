import Foundation

struct GeminiContentClient: ChatProvider {
  let credentialStore: any CloudCredentialStore
  let transport: any CloudNetworkTransport

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard request.route.providerID == CloudProviderID.gemini.rawValue else { throw CloudProviderError.invalidResponse }
          let prepared = try CloudContext.prepare(request)
          guard let key = try credentialStore.apiKey(for: .gemini), !key.isEmpty else { throw CloudProviderError.missingAPIKey(.gemini) }
          let model = request.route.modelID
          guard model.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil else { throw CloudProviderError.invalidResponse }
          var wire = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!)
          wire.httpMethod = "POST"
          wire.setValue(key, forHTTPHeaderField: "x-goog-api-key")
          wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
          var generationConfig: [String: Any] = ["maxOutputTokens": prepared.budget.outputTokens]
          if ThinkCommand.enabled(in: prepared.messages) { generationConfig["thinkingConfig"] = model.hasPrefix("gemini-3") ? ["thinkingLevel": "high"] : ["thinkingBudget": 2_048] }
          wire.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": MultimodalSerialization.messages(prepared.messages, image: request.image, format: .gemini),
            "generationConfig": generationConfig,
          ])
          var parser = ServerSentEventParser()
          var status: Int?
          var errorData = Data()
          var finished = false
          func consume(_ events: [ServerSentEvent]) throws {
            for event in events {
              guard let data = event.data.data(using: .utf8),
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudProviderError.invalidResponse }
              if let error = object["error"] as? [String: Any] { throw CloudProviderError.providerMessage(error["message"] as? String ?? "Gemini request failed.") }
              guard let candidates = object["candidates"] as? [[String: Any]], let candidate = candidates.first else {
                if object["promptFeedback"] != nil { throw CloudProviderError.providerMessage("Gemini could not analyze this request.") }
                continue
              }
              if let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
                for part in parts where part["thought"] as? Bool != true {
                  if let text = part["text"] as? String { continuation.yield(.token(text)) }
                }
              }
              if let reason = candidate["finishReason"] as? String {
                guard reason == "STOP" else { throw CloudProviderError.providerMessage("Gemini stopped the response: \(reason).") }
                finished = true
              }
            }
          }
          for try await event in transport.stream(for: wire) {
            if Task.isCancelled { continue }
            switch event {
            case .response(let code): status = code
            case .data(let data):
              guard let status else { throw CloudProviderError.invalidResponse }
              if (200...299).contains(status) { try consume(parser.append(data)) }
              else { errorData.append(data) }
            }
          }
          try Task.checkCancellation()
          guard let status else { throw CloudProviderError.invalidResponse }
          guard (200...299).contains(status) else { throw cloudHTTPError(provider: .gemini, statusCode: status, data: errorData) }
          try consume(parser.finish())
          guard finished else { throw CloudProviderError.streamEndedUnexpectedly }
          continuation.yield(.completed)
          continuation.finish()
        } catch { continuation.finish(throwing: normalizedCloudError(error)) }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }
}
