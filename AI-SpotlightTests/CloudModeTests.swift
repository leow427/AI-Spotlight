import Foundation
import XCTest
@testable import PrimaryAgent

final class CloudModeTests: XCTestCase {
  func testSSEParserHandlesChunkBoundariesCommentsAndMultipleDataLines() {
    var parser = ServerSentEventParser()
    var events = parser.append(Data("event: message\ndata: first".utf8))
    XCTAssertTrue(events.isEmpty)

    events += parser.append(Data("\ndata: second\n\n: ping\ndata: final\n\n".utf8))

    XCTAssertEqual(events, [
      ServerSentEvent(event: "message", data: "first\nsecond"),
      ServerSentEvent(event: nil, data: "final"),
    ])
  }

  func testOpenAIStreamsResponsesStatelesslyWithStorageDisabled() async throws {
    let credentials = MockCredentialStore(keys: [.openAI: "openai-secret"])
    let transport = MockCloudTransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.response(statusCode: 200))
        continuation.yield(.data(Data("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n".utf8)))
        continuation.yield(.data(Data("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\" cloud\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\"}\n\n".utf8)))
        continuation.finish()
      }
    })
    let client = OpenAIResponsesClient(
      credentialStore: credentials,
      transport: transport
    )

    let events = try await collect(client.stream(makeRequest(provider: .openAI)))

    XCTAssertEqual(events, [.token("Hello"), .token(" cloud"), .completed])
    let sentRequest = try XCTUnwrap(transport.streamRequests.first)
    XCTAssertEqual(sentRequest.value(forHTTPHeaderField: "Authorization"), "Bearer openai-secret")
    let body = try XCTUnwrap(sentRequest.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(object["instructions"] as? String, ChatResponseStyle.instructions)
    XCTAssertEqual(object["store"] as? Bool, false)
    XCTAssertEqual(object["stream"] as? Bool, true)
    XCTAssertNil(object["previous_response_id"])
    XCTAssertEqual((object["input"] as? [[String: Any]])?.count, 3)
    XCTAssertEqual(object["max_output_tokens"] as? Int, 4_096)
  }

  func testAnthropicStreamsMessagesWithRequiredHeaders() async throws {
    let credentials = MockCredentialStore(keys: [.anthropic: "anthropic-secret"])
    let transport = MockCloudTransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.response(statusCode: 200))
        continuation.yield(.data(Data("event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: ping\ndata: {\"type\":\"ping\"}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Claude\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8)))
        continuation.finish()
      }
    })
    let client = AnthropicMessagesClient(
      credentialStore: credentials,
      transport: transport
    )

    let events = try await collect(client.stream(makeRequest(provider: .anthropic)))

    XCTAssertEqual(events, [.token("Claude"), .completed])
    let sentRequest = try XCTUnwrap(transport.streamRequests.first)
    XCTAssertEqual(sentRequest.value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")
    XCTAssertEqual(sentRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    let body = try XCTUnwrap(sentRequest.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(object["stream"] as? Bool, true)
    XCTAssertEqual(object["system"] as? String, ChatResponseStyle.instructions)
    XCTAssertEqual(object["max_tokens"] as? Int, 4_096)
  }

  func testMissingCredentialsDoNotStartANetworkRequest() async {
    let transport = MockCloudTransport()
    let client = OpenAIResponsesClient(
      credentialStore: MockCredentialStore(),
      transport: transport
    )

    do {
      _ = try await collect(client.stream(makeRequest(provider: .openAI)))
      XCTFail("Expected a missing credential error")
    } catch {
      XCTAssertEqual(error as? CloudProviderError, .missingAPIKey(.openAI))
    }
    XCTAssertTrue(transport.streamRequests.isEmpty)
  }

  func testAuthenticationAndRateLimitResponsesAreTyped() async {
    let credentials = MockCredentialStore(keys: [
      .openAI: "openai-secret",
      .anthropic: "anthropic-secret",
    ])
    let authenticationTransport = MockCloudTransport(streamHandler: { _ in
      Self.failedStream(statusCode: 401, message: "Invalid key")
    })
    let rateLimitTransport = MockCloudTransport(streamHandler: { _ in
      Self.failedStream(statusCode: 429, message: "Slow down")
    })

    do {
      _ = try await collect(OpenAIResponsesClient(
        credentialStore: credentials,
        transport: authenticationTransport
      ).stream(makeRequest(provider: .openAI)))
      XCTFail("Expected authentication failure")
    } catch {
      XCTAssertEqual(error as? CloudProviderError, .authenticationFailed(.openAI))
    }

    do {
      _ = try await collect(AnthropicMessagesClient(
        credentialStore: credentials,
        transport: rateLimitTransport
      ).stream(makeRequest(provider: .anthropic)))
      XCTFail("Expected rate limiting")
    } catch {
      XCTAssertEqual(error as? CloudProviderError, .rateLimited(.anthropic))
    }
  }

  func testPartialOutputIsDeliveredBeforeUnexpectedStreamFailure() async {
    let transport = MockCloudTransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.response(statusCode: 200))
        continuation.yield(.data(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n".utf8)))
        continuation.finish()
      }
    })
    let client = OpenAIResponsesClient(
      credentialStore: MockCredentialStore(keys: [.openAI: "secret"]),
      transport: transport
    )
    var events: [ChatEvent] = []

    do {
      for try await event in client.stream(makeRequest(provider: .openAI)) {
        events.append(event)
      }
      XCTFail("Expected an incomplete stream error")
    } catch {
      XCTAssertEqual(error as? CloudProviderError, .streamEndedUnexpectedly)
    }
    XCTAssertEqual(events, [.token("Partial")])
  }

  func testOfflineModelDiscoveryReturnsAnOfflineError() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = CloudModelCatalog(
      credentialStore: MockCredentialStore(keys: [.openAI: "secret"]),
      transport: MockCloudTransport(dataHandler: { _ in
        throw URLError(.notConnectedToInternet)
      }),
      cacheDirectory: root
    )

    do {
      _ = try await catalog.models(for: .openAI)
      XCTFail("Expected an offline error")
    } catch {
      XCTAssertEqual(error as? CloudProviderError, .offline)
    }
  }

  func testModelDiscoveryCacheIsReusedForTwentyFourHours() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = MockCloudTransport(dataHandler: { _ in
      CloudDataResponse(
        data: Data("{\"data\":[{\"id\":\"gpt-4o-mini\"}]}".utf8),
        statusCode: 200
      )
    })
    let catalog = CloudModelCatalog(
      credentialStore: MockCredentialStore(keys: [.openAI: "secret"]),
      transport: transport,
      cacheDirectory: root
    )
    let now = Date(timeIntervalSince1970: 1_000)

    let first = try await catalog.models(for: .openAI, now: now)
    let cached = try await catalog.models(
      for: .openAI,
      now: now.addingTimeInterval(23 * 60 * 60)
    )
    let refreshed = try await catalog.models(
      for: .openAI,
      now: now.addingTimeInterval(25 * 60 * 60)
    )

    XCTAssertEqual(first.map(\.id), ["gpt-4o-mini"])
    XCTAssertEqual(cached, first)
    XCTAssertEqual(refreshed, first)
    XCTAssertEqual(transport.dataRequests.count, 2)
  }

  func testCancellingCloudStreamCancelsUnderlyingNetworkStream() async {
    let cancellation = CloudCancellationProbe()
    let transport = MockCloudTransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.response(statusCode: 200))
        continuation.onTermination = { @Sendable _ in cancellation.record() }
      }
    })
    let client = OpenAIResponsesClient(
      credentialStore: MockCredentialStore(keys: [.openAI: "secret"]),
      transport: transport
    )
    let request = makeRequest(provider: .openAI)
    let task = Task {
      for try await _ in client.stream(request) {}
    }

    await waitUntil { !transport.streamRequests.isEmpty }
    task.cancel()
    _ = await task.result
    await waitUntil { cancellation.wasRecorded }

    XCTAssertTrue(cancellation.wasRecorded)
  }

  func testManualPreferredModelIsPersistedPerProvider() {
    let suiteName = "CloudPreferencesStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = CloudPreferencesStore(defaults: defaults)

    preferences.setPreferredModel("gpt-manual", for: .openAI)
    preferences.setPreferredModel("claude-manual", for: .anthropic)

    XCTAssertEqual(preferences.preferredModel(for: .openAI), "gpt-manual")
    XCTAssertEqual(preferences.preferredModel(for: .anthropic), "claude-manual")
    XCTAssertFalse(
      (defaults.persistentDomain(forName: suiteName) ?? [:]).values
        .contains { ($0 as? String) == "secret" }
    )
  }

  func testDirectProvidersBoundRequestsAndReserveOutputAtSerializationBoundary() async throws {
    for provider in [CloudProviderID.openAI, .anthropic] {
      let transport = MockCloudTransport(streamHandler: { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.response(statusCode: 200))
          let event = provider == .openAI ? "response.completed" : "message_stop"
          continuation.yield(.data(Data("data: {\"type\":\"\(event)\"}\n\n".utf8)))
          continuation.finish()
        }
      })
      let registry = CloudProviderRegistry(
        credentialStore: MockCredentialStore(keys: [provider: "fixture-key"]), transport: transport
      )
      let base = makeRequest(provider: provider)
      let messages = [
        ChatMessage(role: .user, content: String(repeating: "old", count: 4_000)),
        ChatMessage(role: .assistant, content: "old answer"),
      ] + base.messages
      let request = ChatRequest(sessionID: base.sessionID, messages: messages, route: base.route)
      _ = try await collect(registry.provider(for: provider).stream(request))
      let sent = try XCTUnwrap(transport.streamRequests.first?.httpBody)
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
      let outgoing = try XCTUnwrap(body[provider == .openAI ? "input" : "messages"] as? [[String: String]])
      XCTAssertEqual(outgoing.map { $0["content"] }, base.messages.map(\.content))
      XCTAssertEqual(outgoing.map { $0["role"] }, ["user", "assistant", "user"])
      XCTAssertEqual(body[provider == .openAI ? "max_output_tokens" : "max_tokens"] as? Int, 4_096)
      XCTAssertEqual(request.messages.count, 5)
    }
  }

  func testDirectProvidersRejectOversizedPromptBeforeNetwork() async {
    for provider in [CloudProviderID.openAI, .anthropic] {
      let transport = MockCloudTransport()
      let registry = CloudProviderRegistry(
        credentialStore: MockCredentialStore(keys: [provider: "fixture-key"]), transport: transport
      )
      let base = makeRequest(provider: provider)
      let request = ChatRequest(sessionID: base.sessionID, messages: [
        ChatMessage(role: .user, content: String(repeating: "x", count: 40_000)),
      ], route: base.route)
      do {
        _ = try await collect(registry.provider(for: provider).stream(request))
        XCTFail("Oversized request was accepted")
      } catch { XCTAssertTrue(error is ChatContextError) }
      XCTAssertTrue(transport.streamRequests.isEmpty)
    }
  }

  @MainActor
  func testCloudTrimmingPreservesStoredTranscriptForEveryProvider() async throws {
    for provider in CloudProviderID.allCases {
      let root = FileManager.default.temporaryDirectory.appending(path: "CloudContextPersistence-\(UUID())")
      defer { try? FileManager.default.removeItem(at: root) }
      let store = ChatSessionStore(applicationSupportDirectory: root)
      let original = [
        ChatMessage(role: .user, content: String(repeating: "old", count: 20_000)),
        ChatMessage(role: .assistant, content: "old reply"),
        ChatMessage(role: .user, content: "recent"),
        ChatMessage(role: .assistant, content: "recent reply"),
      ]
      try store.save([ChatSession(messages: original)])
      let persistedOriginal = store.load()[0].messages
      let ended = expectation(description: "Cloud request completed")
      let transport = MockCloudTransport(streamHandler: { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.response(statusCode: 200))
          let event = provider == .openAI ? "response.completed" : "message_stop"
          continuation.yield(.data(Data("data: {\"type\":\"\(event)\"}\n\n".utf8)))
          continuation.finish()
          ended.fulfill()
        }
      })
      let registry = CloudProviderRegistry(
        credentialStore: MockCredentialStore(keys: [provider: "fixture-key"]),
        transport: transport,
        chatGPT: ContextCompletionProvider(onRequest: { request in
          XCTAssertEqual(request.messages.map(\.content), ["recent", "recent reply", "current"])
          ended.fulfill()
        })
      )
      let viewModel = LocalChatViewModel(
        engine: LlamaCPPModelEngine(installationStore: LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))),
        cloudProviders: registry, sessionStore: store
      )
      var draft = "current"
      viewModel.submitCloud(draft, provider: provider, modelID: "manual", onAccepted: { draft = "" })
      XCTAssertEqual(draft, "")
      await fulfillment(of: [ended], timeout: 2)
      XCTAssertEqual(Array(store.load()[0].messages.prefix(4)), persistedOriginal)
      XCTAssertEqual(store.load()[0].messages.count, 6)
      XCTAssertNotNil(viewModel.contextNotice)
    }
  }

  private func makeRequest(provider: CloudProviderID) -> ChatRequest {
    ChatRequest(
      sessionID: UUID(),
      messages: [
        ChatMessage(role: .user, content: "Previous question"),
        ChatMessage(role: .assistant, content: "Previous answer"),
        ChatMessage(role: .user, content: "Current question"),
      ],
      route: Route(
        mode: .cloud,
        providerID: provider.rawValue,
        modelID: provider == .openAI ? "gpt-test" : "claude-test",
        usesNetwork: true
      )
    )
  }

  private func collect(
    _ stream: AsyncThrowingStream<ChatEvent, Error>
  ) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private static func failedStream(
    statusCode: Int,
    message: String
  ) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.response(statusCode: statusCode))
      continuation.yield(.data(Data("{\"error\":{\"message\":\"\(message)\"}}".utf8)))
      continuation.finish()
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "CloudModeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func waitUntil(
    _ condition: @escaping @Sendable () -> Bool
  ) async {
    // Scheduler yields do not provide a time budget on a busy CI runner.
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition was not satisfied")
  }
}

private final class MockCredentialStore: CloudCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [CloudProviderID: String]

  init(keys: [CloudProviderID: String] = [:]) {
    self.keys = keys
  }

  func apiKey(for provider: CloudProviderID) throws -> String? {
    access { keys[provider] }
  }

  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {
    access { keys[provider] = apiKey }
  }

  func removeAPIKey(for provider: CloudProviderID) throws {
    _ = access { keys.removeValue(forKey: provider) }
  }

  private func access<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

private final class MockCloudTransport: CloudNetworkTransport, @unchecked Sendable {
  typealias DataHandler = @Sendable (URLRequest) async throws -> CloudDataResponse
  typealias StreamHandler = @Sendable (URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error>

  private let lock = NSLock()
  private let dataHandler: DataHandler
  private let streamHandler: StreamHandler
  private var storedDataRequests: [URLRequest] = []
  private var storedStreamRequests: [URLRequest] = []

  init(
    dataHandler: @escaping DataHandler = { _ in
      CloudDataResponse(data: Data(), statusCode: 200)
    },
    streamHandler: @escaping StreamHandler = { _ in
      AsyncThrowingStream { $0.finish() }
    }
  ) {
    self.dataHandler = dataHandler
    self.streamHandler = streamHandler
  }

  var dataRequests: [URLRequest] { access { storedDataRequests } }
  var streamRequests: [URLRequest] { access { storedStreamRequests } }

  func data(for request: URLRequest) async throws -> CloudDataResponse {
    access { storedDataRequests.append(request) }
    return try await dataHandler(request)
  }

  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    access { storedStreamRequests.append(request) }
    return streamHandler(request)
  }

  private func access<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

private final class CloudCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded = false

  var wasRecorded: Bool { access { recorded } }

  func record() {
    access { recorded = true }
  }

  private func access<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

private struct ContextCompletionProvider: ChatProvider {
  let onRequest: @Sendable (ChatRequest) -> Void

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    onRequest(request)
    return AsyncThrowingStream { $0.yield(.completed); $0.finish() }
  }
}
