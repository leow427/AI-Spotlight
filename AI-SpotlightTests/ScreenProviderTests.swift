import XCTest
@testable import PrimaryAgent

final class ScreenProviderTests: XCTestCase {
  private let image = PreparedScreenImage(data: Data([0xff, 0xd8, 0xff, 0xd9]), mimeType: "image/jpeg", pixelWidth: 10, pixelHeight: 10)
  private let messages = [ChatMessage(role: .user, content: "earlier"), ChatMessage(role: .assistant, content: "reply"), ChatMessage(role: .user, content: "describe")]

  func testEveryProviderSerializesTheSameNeutralImageOnlyOnCurrentTurn() throws {
    let raw = image.data.base64EncodedString()
    for format in [MultimodalSerialization.Format.openAIChat, .openAIResponses, .anthropic, .gemini, .ollama] {
      let encoded = try MultimodalSerialization.messages(messages, image: image, format: format)
      let wire = String(decoding: try JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
      XCTAssertEqual(wire.components(separatedBy: raw).count - 1, 1)
      switch format {
      case .openAIChat:
        let parts = try XCTUnwrap(encoded.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
        XCTAssertEqual((parts.last?["image_url"] as? [String: String])?["url"], "data:image/jpeg;base64," + raw)
      case .openAIResponses:
        let parts = try XCTUnwrap(encoded.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.last?["type"] as? String, "input_image")
      case .anthropic:
        let parts = try XCTUnwrap(encoded.last?["content"] as? [[String: Any]])
        let source = try XCTUnwrap(parts.last?["source"] as? [String: String])
        XCTAssertEqual(source, ["type": "base64", "media_type": "image/jpeg", "data": raw])
      case .gemini:
        XCTAssertEqual(encoded[1]["role"] as? String, "model")
        let parts = try XCTUnwrap(encoded.last?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.last?["inlineData"] as? [String: String], ["mimeType": "image/jpeg", "data": raw])
      case .ollama:
        XCTAssertEqual(encoded.last?["images"] as? [String], [raw])
        XCTAssertNil(encoded[0]["images"])
      }
    }
  }

  func testProviderBoundaryRejectsImagesBeforeAnyNetworkRequest() async {
    for provider in [CloudProviderID.openAI, .anthropic, .gemini] {
      let transport = ScreenTestTransport()
      let registry = CloudProviderRegistry(credentialStore: ScreenTestCredentialStore(keys: [provider: "fixture"]), transport: transport)
      for mode in [ChatMode.local, .cloud] {
        var request = ChatRequest(sessionID: UUID(), messages: messages, route: Route(mode: mode, providerID: provider.rawValue, modelID: CloudModelCapabilities.visionModelIDs(for: provider)[0], usesNetwork: true), image: image)
        request.allowsCloudImages = mode == .local
        do {
          for try await _ in registry.provider(for: provider).stream(request) {}
          XCTFail("Image should be blocked")
        } catch { XCTAssertEqual(error as? ScreenRequestError, .cloudUploadNotAllowed) }
      }
      XCTAssertTrue(transport.streamRequests.isEmpty)
      let request = ChatRequest(sessionID: UUID(), messages: messages, route: Route(mode: .cloud, providerID: provider.rawValue, modelID: "text-only-unknown", usesNetwork: true), image: image, allowsCloudImages: true)
      do { for try await _ in registry.provider(for: provider).stream(request) {}; XCTFail("Text-only model") }
      catch { XCTAssertEqual(error as? ScreenRequestError, .textOnlyModel) }
      XCTAssertTrue(transport.streamRequests.isEmpty)
    }
  }

  func testActualCloudAdaptersSendImageBlocksWithPermission() async throws {
    for provider in [CloudProviderID.openAI, .anthropic, .gemini] {
      let completion: String
      switch provider {
      case .openAI: completion = #"{"type":"response.completed"}"#
      case .anthropic: completion = #"{"type":"message_stop"}"#
      default: completion = #"{"candidates":[{"content":{"parts":[{"text":"done"}]},"finishReason":"STOP"}]}"#
      }
      let transport = ScreenTestTransport(streamHandler: { _ in
        AsyncThrowingStream { c in
          c.yield(.response(statusCode: 200)); c.yield(.data(Data("data: \(completion)\n\n".utf8))); c.finish()
        }
      })
      let registry = CloudProviderRegistry(credentialStore: ScreenTestCredentialStore(keys: [provider: "fixture"]), transport: transport)
      let request = ChatRequest(sessionID: UUID(), messages: messages, route: Route(mode: .cloud, providerID: provider.rawValue, modelID: CloudModelCapabilities.visionModelIDs(for: provider)[0], usesNetwork: true), image: image, allowsCloudImages: true)
      for try await _ in registry.provider(for: provider).stream(request) {}
      let wire = try XCTUnwrap(transport.streamRequests.first?.httpBody)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
      XCTAssertNotNil(object[provider == .gemini ? "contents" : (provider == .openAI ? "input" : "messages")])
    }
  }

  func testCloudThinkingControlsAreSentOnlyForThinkingRequests() async throws {
    for provider in [CloudProviderID.openAI, .anthropic, .gemini] {
      let completion: String
      switch provider {
      case .openAI: completion = #"{"type":"response.completed"}"#
      case .anthropic: completion = #"{"type":"message_stop"}"#
      default: completion = #"{"candidates":[{"content":{"parts":[{"text":"done"}]},"finishReason":"STOP"}]}"#
      }
      let transport = ScreenTestTransport(streamHandler: { _ in
        AsyncThrowingStream { c in
          c.yield(.response(statusCode: 200)); c.yield(.data(Data("data: \(completion)\n\n".utf8))); c.finish()
        }
      })
      let registry = CloudProviderRegistry(credentialStore: ScreenTestCredentialStore(keys: [provider: "fixture"]), transport: transport)
      for enabled in [true, false] {
        let request = ChatRequest(sessionID: UUID(), messages: [ThinkCommand.message(enabled ? "/think solve" : "solve")],
          route: Route(mode: .cloud, providerID: provider.rawValue, modelID: CloudModelCapabilities.visionModelIDs(for: provider)[0], usesNetwork: true))
        for try await _ in registry.provider(for: provider).stream(request) {}
        let wire = try XCTUnwrap(transport.streamRequests.last?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let control = provider == .gemini ? (object["generationConfig"] as? [String: Any])?["thinkingConfig"] : object[provider == .openAI ? "reasoning" : "thinking"]
        XCTAssertEqual(control != nil, enabled)
      }
    }
    XCTAssertEqual(CodexThinkingCapacity.high.forExtendedThinking, .xhigh)
    XCTAssertEqual(CodexThinkingCapacity.ultra.forExtendedThinking, .ultra)
  }

  func testThinkingIsPerRequestAndReservesSpaceBeforeGeneration() throws {
    let thinking = ThinkCommand.message("/think solve this")
    XCTAssertEqual(thinking.content, "solve this")
    XCTAssertTrue(ThinkCommand.enabled(in: [thinking]))
    let request = LocalModelRequest(messages: [thinking])
    XCTAssertEqual(request.maximumTokenCount, 2_048)
    let prepared = try ChatContextPreparer.prepare(request.messages,
      budget: ContextBudget(contextWindow: 4096, outputTokens: 2048, overheadTokens: 256),
      countTokens: { $0.reduce(0) { $0 + $1.content.utf8.count } })
    XCTAssertTrue(prepared.messages.last!.content.hasPrefix(ThinkCommand.guidance))
    let client = LocalMultimodalClient(endpoint: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
      api: .openAICompatible, transport: ScreenTestTransport())
    let model = ScreenModel(id: "fixture", provider: "llama.cpp", isLocal: true, capabilities: .textAndVision)
    for enabled in [true, false] {
      let messages = enabled ? prepared.messages : [thinking, ChatMessage(role: .assistant, content: "done"), ThinkCommand.message("next")]
      let wire = try client.makeRequest(messages: messages, image: nil, model: model,
        maximumTokens: ThinkCommand.localOutputTokens(messages))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: wire.httpBody!) as? [String: Any])
      XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], enabled)
      XCTAssertEqual(body["max_tokens"] as? Int, enabled ? 2048 : 512)
      XCTAssertEqual(body["reasoning_budget"] as? Int, enabled ? 1024 : 0)
    }
    let stored = try JSONEncoder().encode(thinking)
    XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: stored).extendedThinking)
  }

  func testLocalAdaptersRejectRemoteEndpointsAndTextOnlyModels() throws {
    let model = ScreenModel(id: "vision", provider: "ollama", isLocal: true, capabilities: .textAndVision)
    let transport = ScreenTestTransport()
    let remote = LocalMultimodalClient(endpoint: URL(string: "http://example.com/api/chat")!, api: .ollama, transport: transport)
    XCTAssertThrowsError(try remote.makeRequest(messages: messages, image: image, model: model))
    let client = LocalMultimodalClient(endpoint: URL(string: "http://127.0.0.1:11434/api/chat")!, api: .ollama, transport: transport)
    let request = try client.makeRequest(messages: messages, image: image, model: model)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    XCTAssertEqual(((object["messages"] as? [[String: Any]])?.last?["images"] as? [String])?.count, 1)
    XCTAssertThrowsError(try client.makeRequest(messages: messages, image: image, model: ScreenModel(id: "text", provider: "ollama", isLocal: true, capabilities: .textOnly)))
  }
}
