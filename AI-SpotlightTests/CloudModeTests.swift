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
    XCTAssertEqual(object["store"] as? Bool, false)
    XCTAssertEqual(object["stream"] as? Bool, true)
    XCTAssertNil(object["previous_response_id"])
    XCTAssertEqual((object["input"] as? [[String: Any]])?.count, 2)
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
        data: Data("{\"data\":[{\"id\":\"gpt-test\"}]}".utf8),
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

    XCTAssertEqual(first.map(\.id), ["gpt-test"])
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

  func testBackendSessionTakesPrecedenceAndRoutesOpenAIThroughBackend() async throws {
    let transport = MockCloudTransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.response(statusCode: 200))
        continuation.yield(.data(Data("data: {\"type\":\"response.completed\"}\n\n".utf8)))
        continuation.finish()
      }
    })
    let resolver = PreferredCloudAccessResolver(
      credentialStore: MockCredentialStore(keys: [.openAI: "provider-key"]),
      sessionStore: MockCloudAccountSessionStore(
        session: CloudAccountSession(
          accessToken: "account-session",
          expiresAt: .now.addingTimeInterval(3_600)
        )
      ),
      backend: CloudBackendConfiguration(baseURL: URL(string: "https://cloud.example")!)
    )
    let client = OpenAIResponsesClient(accessResolver: resolver, transport: transport)

    _ = try await collect(client.stream(makeRequest(provider: .openAI)))

    let sentRequest = try XCTUnwrap(transport.streamRequests.first)
    XCTAssertEqual(
      sentRequest.url?.absoluteString,
      "https://cloud.example/v1/providers/openai/responses"
    )
    XCTAssertEqual(
      sentRequest.value(forHTTPHeaderField: "Authorization"),
      "Bearer account-session"
    )
    XCTAssertFalse(sentRequest.allHTTPHeaderFields?.values.contains("provider-key") ?? true)
  }

  func testBackendAnthropicRequestUsesSessionWithoutAPIKeyHeader() async throws {
    let transport = MockCloudTransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.response(statusCode: 200))
        continuation.yield(.data(Data("data: {\"type\":\"message_stop\"}\n\n".utf8)))
        continuation.finish()
      }
    })
    let resolver = PreferredCloudAccessResolver(
      credentialStore: MockCredentialStore(keys: [.anthropic: "provider-key"]),
      sessionStore: MockCloudAccountSessionStore(
        session: CloudAccountSession(
          accessToken: "account-session",
          expiresAt: .now.addingTimeInterval(3_600)
        )
      ),
      backend: CloudBackendConfiguration(baseURL: URL(string: "https://cloud.example")!)
    )
    let client = AnthropicMessagesClient(accessResolver: resolver, transport: transport)

    _ = try await collect(client.stream(makeRequest(provider: .anthropic)))

    let sentRequest = try XCTUnwrap(transport.streamRequests.first)
    XCTAssertEqual(
      sentRequest.url?.absoluteString,
      "https://cloud.example/v1/providers/anthropic/messages"
    )
    XCTAssertEqual(
      sentRequest.value(forHTTPHeaderField: "Authorization"),
      "Bearer account-session"
    )
    XCTAssertNil(sentRequest.value(forHTTPHeaderField: "x-api-key"))
  }

  func testExpiredBackendSessionFallsBackToPersonalAPIKey() throws {
    let resolver = PreferredCloudAccessResolver(
      credentialStore: MockCredentialStore(keys: [.openAI: "provider-key"]),
      sessionStore: MockCloudAccountSessionStore(
        session: CloudAccountSession(accessToken: "expired", expiresAt: .distantPast)
      ),
      backend: CloudBackendConfiguration(baseURL: URL(string: "https://cloud.example")!)
    )

    let access = try XCTUnwrap(resolver.access(for: .openAI))

    XCTAssertEqual(access.kind, .directAPIKey)
    XCTAssertEqual(access.credential, "provider-key")
    XCTAssertNil(access.backendURL)
  }

  func testBackendModelDiscoveryUsesAccountSession() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = MockCloudTransport(dataHandler: { _ in
      CloudDataResponse(
        data: Data("{\"data\":[{\"id\":\"gpt-account\"}]}".utf8),
        statusCode: 200
      )
    })
    let resolver = PreferredCloudAccessResolver(
      credentialStore: MockCredentialStore(),
      sessionStore: MockCloudAccountSessionStore(
        session: CloudAccountSession(
          accessToken: "account-session",
          expiresAt: .now.addingTimeInterval(3_600)
        )
      ),
      backend: CloudBackendConfiguration(baseURL: URL(string: "https://cloud.example")!)
    )
    let catalog = CloudModelCatalog(
      accessResolver: resolver,
      transport: transport,
      cacheDirectory: root
    )

    let models = try await catalog.models(for: .openAI, forceRefresh: true)

    XCTAssertEqual(models.map(\.id), ["gpt-account"])
    let sentRequest = try XCTUnwrap(transport.dataRequests.first)
    XCTAssertEqual(
      sentRequest.url?.absoluteString,
      "https://cloud.example/v1/providers/openai/models"
    )
    XCTAssertEqual(
      sentRequest.value(forHTTPHeaderField: "Authorization"),
      "Bearer account-session"
    )
  }

  func testAppleIdentityTokenIsExchangedForExpiringBackendSession() async throws {
    let fixedNow = Date(timeIntervalSince1970: 1_000)
    let transport = MockCloudTransport(dataHandler: { _ in
      CloudDataResponse(
        data: Data("{\"access_token\":\"backend-token\",\"expires_in\":600}".utf8),
        statusCode: 200
      )
    })
    let client = URLSessionCloudAccountClient(
      backend: CloudBackendConfiguration(baseURL: URL(string: "https://cloud.example")!),
      transport: transport,
      now: { fixedNow }
    )

    let session = try await client.signIn(
      identityToken: Data("apple-identity-token".utf8),
      nonce: "raw-nonce"
    )

    XCTAssertEqual(session.accessToken, "backend-token")
    XCTAssertEqual(session.expiresAt, fixedNow.addingTimeInterval(600))
    let request = try XCTUnwrap(transport.dataRequests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://cloud.example/v1/auth/apple")
    let body = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
    XCTAssertEqual(object["identity_token"], "apple-identity-token")
    XCTAssertEqual(object["nonce"], "raw-nonce")
  }

  func testBackendConfigurationRequiresHTTPS() {
    XCTAssertNil(CloudBackendConfiguration(rawURL: nil).baseURL)
    XCTAssertNil(CloudBackendConfiguration(rawURL: "http://cloud.example").baseURL)
    XCTAssertEqual(
      CloudBackendConfiguration(rawURL: " https://cloud.example ").baseURL,
      URL(string: "https://cloud.example")
    )
  }

  private func makeRequest(provider: CloudProviderID) -> ChatRequest {
    ChatRequest(
      sessionID: UUID(),
      messages: [
        ChatMessage(role: .user, content: "Previous question"),
        ChatMessage(role: .assistant, content: "Previous answer"),
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
    _ condition: @escaping @Sendable () -> Bool,
    iterations: Int = 1_000
  ) async {
    for _ in 0..<iterations {
      if condition() { return }
      await Task.yield()
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

private final class MockCloudAccountSessionStore: CloudAccountSessionStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var storedSession: CloudAccountSession?

  init(session: CloudAccountSession? = nil) {
    storedSession = session
  }

  func session() throws -> CloudAccountSession? {
    access { storedSession }
  }

  func setSession(_ session: CloudAccountSession) throws {
    access { storedSession = session }
  }

  func removeSession() throws {
    access { storedSession = nil }
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
