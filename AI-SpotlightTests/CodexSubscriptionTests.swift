import Foundation
import XCTest
@testable import PrimaryAgent

final class CodexSubscriptionTests: XCTestCase {
  func testJSONRoundTripPreservesUnicodeAndNestedValues() throws {
    let value = CodexValue.object([
      "text": .string("Hello 👋\nCopenhagen"), "id": .number(42),
      "items": .array([.bool(false), .null, .object(["ok": .bool(true)])]),
    ])
    XCTAssertEqual(try JSONDecoder().decode(CodexValue.self, from: JSONEncoder().encode(value)), value)
    XCTAssertEqual(value["id"].integer, 42)
    XCTAssertEqual(value["missing"], .null)
  }

  func testRuntimeIsolatesCredentialsAndDisablesExternalActions() {
    let configuration = CodexRuntimeConfiguration(directory: URL(fileURLWithPath: "/tmp/ai-spotlight-codex"))
    XCTAssertEqual(configuration.environment["CODEX_HOME"], "/tmp/ai-spotlight-codex")
    XCTAssertNil(configuration.environment["OPENAI_API_KEY"])
    XCTAssertNil(configuration.environment["CODEX_API_KEY"])
    XCTAssertNil(configuration.environment["OPENAI_BASE_URL"])
    for setting in [
      "forced_login_method=\"chatgpt\"", "cli_auth_credentials_store=\"keyring\"",
      "model_provider=\"openai\"", "web_search=\"disabled\"", "history.persistence=\"none\"",
      "features.shell_tool=false", "features.apps=false", "features.plugins=false",
      "features.hooks=false", "features.multi_agent=false", "features.computer_use=false",
    ] {
      XCTAssertTrue(configuration.arguments.contains(setting), setting)
    }
  }

  func testMissingCodexReturnsActionableErrorWithoutLaunching() async {
    let server = CodexAppServer(executable: { nil })
    do {
      _ = try await server.request("account/read", params: .object([:]))
      XCTFail("Expected missing runtime")
    } catch {
      XCTAssertEqual(error as? CodexError, .notInstalled)
    }
  }

  func testAppServerInitializesAndCorrelatesARealPipeResponse() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeExecutable(in: root, script: """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*) /usr/bin/printf '%s\\n' '{"id":1,"result":{}}' ;;
          *'"method":"account/read"'*) /usr/bin/printf '%s\\n' '{"id":2,"result":{"account":null}}' ;;
        esac
      done
      """)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")), executable: { executable }, requestTimeout: .seconds(5))
    let result = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(result, .object(["account": .null]))
    await server.disconnect()
  }

  func testAppServerEOFAndTimeoutDoNotLeaveRequestsHanging() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeExecutable(in: root, script: """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*) /usr/bin/printf '%s\\n' '{"id":1,"result":{}}' ;;
          *'"method":"exit"'*) exit 0 ;;
        esac
      done
      """)
    let server = CodexAppServer(
      configuration: .init(directory: root.appending(path: "runtime")),
      executable: { executable }, requestTimeout: .seconds(1)
    )
    do {
      _ = try await server.request("unanswered", params: .object([:]))
      XCTFail("Expected a timeout")
    } catch { XCTAssertEqual(error as? CodexError, .timedOut) }
    do {
      _ = try await server.request("exit", params: .object([:]))
      XCTFail("Expected disconnection")
    } catch { XCTAssertEqual(error as? CodexError, .disconnected) }
    await server.disconnect()
  }

  func testAPIKeyAccountIsRejectedBySubscriptionRoute() async {
    let transport = MockCodexTransport(account: .object(["type": .string("apiKey")]))
    let client = CodexSubscriptionClient(transport: transport)
    do {
      _ = try await client.account()
      XCTFail("API billing must not masquerade as subscription access")
    } catch { XCTAssertEqual(error as? CodexError, .notSignedIn) }
  }

  func testBrowserLoginUsesSupportedOAuthAndHandlesEarlyCompletion() async throws {
    let transport = MockCodexTransport(loginSuccess: true)
    let client = CodexSubscriptionClient(transport: transport)
    let opened = expectation(description: "Official OAuth URL opened")
    let account = try await client.signIn { url in
      XCTAssertEqual(url.host, "auth.openai.com")
      opened.fulfill()
      return true
    }
    XCTAssertEqual(account, CodexAccount(email: "person@example.com", plan: "plus"))
    await fulfillment(of: [opened], timeout: 1)
    let requests = await transport.recordedRequests
    let login = try XCTUnwrap(requests.first { $0.method == "account/login/start" })
    XCTAssertEqual(login.params["type"].string, "chatgpt")
    XCTAssertEqual(login.params["useHostedLoginSuccessPage"].bool, true)
    XCTAssertEqual(login.params["apiKey"], .null)
  }

  func testFailedLoginAndUnsafeBrowserURLAreRejected() async {
    let failed = CodexSubscriptionClient(transport: MockCodexTransport(loginSuccess: false))
    do {
      _ = try await failed.signIn { _ in true }
      XCTFail("Expected login failure")
    } catch { XCTAssertEqual(error as? CodexError, .server("Login denied")) }
    let unsafe = CodexSubscriptionClient(transport: MockCodexTransport(loginURL: "http://untrusted.example/login"))
    do {
      _ = try await unsafe.signIn { _ in XCTFail("Must not open untrusted URL"); return true }
      XCTFail("Expected invalid URL")
    } catch { XCTAssertEqual(error as? CodexError, .invalidResponse) }
  }

  func testCancellingLoginCancelsServerSideBrowserFlow() async {
    let opened = expectation(description: "Login opened")
    let cancelled = expectation(description: "Login cancelled on server")
    let transport = MockCodexTransport(onRequest: { method in
      if method == "account/login/cancel" { cancelled.fulfill() }
    })
    let client = CodexSubscriptionClient(transport: transport)
    let task = Task { try await client.signIn { _ in opened.fulfill(); return true } }
    await fulfillment(of: [opened], timeout: 2)
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    await fulfillment(of: [cancelled], timeout: 2)
  }

  func testModelsUseRunnableModelNamesAndFollowPagination() async throws {
    let client = CodexSubscriptionClient(transport: MockCodexTransport())
    let models = try await client.models()
    XCTAssertEqual(models.map(\.id), ["model-one", "model-two"])
    XCTAssertEqual(models.map(\.provider), [.chatGPT, .chatGPT])
  }

  func testNewCloudPreferencesDefaultToLunaWithoutChangingAPIDefaults() {
    let suite = "CodexSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = CloudPreferencesStore(defaults: defaults)
    XCTAssertEqual(preferences.preferredProvider(), .chatGPT)
    XCTAssertEqual(preferences.preferredModel(for: .chatGPT), "gpt-5.6-luna")
    XCTAssertEqual(preferences.preferredModel(for: .openAI), "")
    XCTAssertEqual(preferences.preferredModel(for: .anthropic), "")
    XCTAssertEqual(preferences.preferredCodexThinkingCapacity(), .high)

    preferences.setPreferredModel(" \n", for: .chatGPT)
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).preferredModel(for: .chatGPT), "gpt-5.6-luna")
    preferences.setPreferredCodexThinkingCapacity(.ultra)
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).preferredCodexThinkingCapacity(), .ultra)
  }

  func testPreviousSolDefaultMigratesOnlyOnceAndPreservesAPISettings() {
    let suite = "CodexSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("gpt-5.6-sol", forKey: "aiSpotlight.cloud.preferredModel.chatgpt-codex")
    defaults.set("openai", forKey: "aiSpotlight.cloud.preferredProvider")
    defaults.set("openai-model", forKey: "aiSpotlight.cloud.preferredModel.openai")
    defaults.set("anthropic-model", forKey: "aiSpotlight.cloud.preferredModel.anthropic")

    let preferences = CloudPreferencesStore(defaults: defaults)
    XCTAssertEqual(preferences.preferredModel(for: .chatGPT), "gpt-5.6-luna")
    XCTAssertEqual(preferences.preferredProvider(), .openAI)
    XCTAssertEqual(preferences.preferredModel(for: .openAI), "openai-model")
    XCTAssertEqual(preferences.preferredModel(for: .anthropic), "anthropic-model")

    preferences.setPreferredModel("gpt-5.6-sol", for: .chatGPT)
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).preferredModel(for: .chatGPT), "gpt-5.6-sol")
  }

  func testLunaDefaultMigrationPreservesOtherSavedChatGPTModels() {
    let suite = "CodexSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("custom-model", forKey: "aiSpotlight.cloud.preferredModel.chatgpt-codex")
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).preferredModel(for: .chatGPT), "custom-model")
  }

  func testCodexStreamSendsTheSelectedThinkingCapacity() async throws {
    let transport = MockCodexTransport(turnNotifications: [delta("Hello"), completion("completed")])
    let client = CodexSubscriptionClient(transport: transport, thinkingCapacity: { .ultra })
    let events = try await collect(client.stream(request(modelID: "gpt-5.6-luna")))
    XCTAssertEqual(events, [.token("Hello"), .completed])
    let requests = await transport.recordedRequests
    let thread = try XCTUnwrap(requests.first { $0.method == "thread/start" })
    XCTAssertEqual(thread.params["model"].string, "gpt-5.6-luna")
    let turn = try XCTUnwrap(requests.first { $0.method == "turn/start" })
    XCTAssertEqual(turn.params["threadId"].string, "thread-one")
    XCTAssertEqual(turn.params["effort"].string, "ultra")
  }

  func testSubscriptionStreamIsEphemeralAndPreservesConversationContext() async throws {
    let cleanup = expectation(description: "Thread unloaded")
    let transport = MockCodexTransport(turnNotifications: [
      delta("Ignore", thread: "other"), delta("Hello"), delta(" 👋"), completion("completed"),
    ], onRequest: { method in
      if method == "thread/unsubscribe" { cleanup.fulfill() }
    })
    let events = try await collect(CodexSubscriptionClient(transport: transport).stream(request()))
    XCTAssertEqual(events, [.token("Hello"), .token(" 👋"), .completed])
    await fulfillment(of: [cleanup], timeout: 2)
    let requests = await transport.recordedRequests
    let thread = try XCTUnwrap(requests.first { $0.method == "thread/start" })
    XCTAssertEqual(thread.params["ephemeral"].bool, true)
    XCTAssertEqual(thread.params["sandbox"].string, "read-only")
    XCTAssertEqual(thread.params["approvalPolicy"].string, "never")
    XCTAssertEqual(thread.params["modelProvider"].string, "openai")
    let turn = try XCTUnwrap(requests.first { $0.method == "turn/start" })
    XCTAssertEqual(turn.params["effort"].string, "high")
    let text = try XCTUnwrap(turn.params["input"].array?.first?["text"].string)
    XCTAssertTrue(text.contains("Previous answer"))
    XCTAssertTrue(text.contains("Latest question"))
    XCTAssertFalse(requests.contains { $0.method == "turn/interrupt" })
  }

  func testPartialTextIsPreservedWhenCodexReportsFailure() async {
    let client = CodexSubscriptionClient(transport: MockCodexTransport(turnNotifications: [
      delta("Partial"), completion("failed", message: "Usage limit reached"),
    ]))
    var events: [ChatEvent] = []
    do {
      for try await event in client.stream(request()) { events.append(event) }
      XCTFail("Expected failure")
    } catch { XCTAssertEqual(error as? CodexError, .server("Usage limit reached")) }
    XCTAssertEqual(events, [.token("Partial")])
  }

  func testStopInterruptsEvenWhenTurnStartResponseIsStillPending() async {
    let started = expectation(description: "Turn submitted")
    let interrupted = expectation(description: "Turn interrupted")
    let unloaded = expectation(description: "Thread unloaded")
    let transport = MockCodexTransport(delayTurnStart: true, onRequest: { method in
      if method == "turn/start" { started.fulfill() }
      if method == "turn/interrupt" { interrupted.fulfill() }
      if method == "thread/unsubscribe" { unloaded.fulfill() }
    })
    let client = CodexSubscriptionClient(transport: transport)
    let request = request()
    let task = Task { for try await _ in client.stream(request) {} }
    await fulfillment(of: [started], timeout: 2)
    task.cancel()
    await transport.releaseTurnStart()
    _ = await task.result
    await fulfillment(of: [interrupted, unloaded], timeout: 2)
    let calls = await transport.recordedRequests
    XCTAssertEqual(calls.first { $0.method == "turn/interrupt" }?.params["turnId"].string, "turn-one")
  }

  func testMissingLoginNeverFallsBackToStoredAPIKey() async {
    let codex = CodexSubscriptionClient(transport: MockCodexTransport(account: .null))
    let registry = CloudProviderRegistry(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(), chatGPT: codex)
    do {
      _ = try await collect(registry.provider(for: .chatGPT).stream(request()))
      XCTFail("Expected sign-in requirement")
    } catch { XCTAssertEqual(error as? CodexError, .notSignedIn) }
  }

  @MainActor
  func testSettingsRestoreAccountAndSignOutWithoutTouchingAPIKeys() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "CodexSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let transport = MockCodexTransport()
    let client = CodexSubscriptionClient(transport: transport)
    let catalog = CloudModelCatalog(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(), cacheDirectory: root, codex: client)
    let settings = CloudSettingsModel(
      credentialStore: CodexTestCredentials(), catalog: catalog,
      preferences: CloudPreferencesStore(defaults: defaults), codex: client, codexAvailable: { true }
    )
    XCTAssertEqual(settings.preferredProvider, .chatGPT)
    XCTAssertFalse(settings.isConfigured)
    await settings.refreshChatGPTAccount()
    await settings.discoverModels()
    XCTAssertTrue(settings.isConfigured)
    XCTAssertEqual(settings.preferredModelID, "gpt-5.6-luna")
    XCTAssertEqual(settings.models.map(\.id), ["model-one", "model-two"])
    settings.preferredModelID = ""
    await settings.loadCachedModels()
    XCTAssertEqual(settings.preferredModelID, "gpt-5.6-luna", "Catalog order must not replace the lighter default")
    settings.preferredModelID = "model-two"
    await settings.discoverModels(forceRefresh: true)
    XCTAssertEqual(settings.preferredModelID, "model-two", "Refresh must preserve an explicit model selection")
    XCTAssertFalse(settings.hasAPIKey(for: .chatGPT))
    await settings.signOutOfChatGPT()
    XCTAssertFalse(settings.isConfigured)
    XCTAssertTrue(settings.models.isEmpty)
    XCTAssertTrue(settings.hasAPIKey(for: .openAI))
    let cached = await catalog.cachedModels(for: .chatGPT)
    XCTAssertNil(cached)
    XCTAssertFalse((defaults.persistentDomain(forName: suite) ?? [:]).keys.contains { $0.lowercased().contains("token") })
  }

  private func request(modelID: String = "model-one") -> ChatRequest {
    ChatRequest(sessionID: UUID(), messages: [
      ChatMessage(role: .user, content: "Previous question"),
      ChatMessage(role: .assistant, content: "Previous answer"),
      ChatMessage(role: .user, content: "Latest question"),
    ], route: Route(mode: .cloud, providerID: CloudProviderID.chatGPT.rawValue, modelID: modelID, usesNetwork: true))
  }

  private func delta(_ text: String, thread: String = "thread-one") -> CodexNotification {
    CodexNotification(method: "item/agentMessage/delta", params: .object([
      "threadId": .string(thread), "turnId": .string("turn-one"), "itemId": .string("message-one"), "delta": .string(text),
    ]))
  }

  private func completion(_ status: String, message: String = "") -> CodexNotification {
    CodexNotification(method: "turn/completed", params: .object([
      "threadId": .string("thread-one"),
      "turn": .object(["id": .string("turn-one"), "status": .string(status), "error": .object(["message": .string(message)])]),
    ]))
  }

  private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "CodexTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeExecutable(in directory: URL, script: String) throws -> URL {
    let url = directory.appending(path: "fake-codex")
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
}

private actor MockCodexTransport: CodexRPCTransport {
  struct Request: Sendable {
    let method: String
    let params: CodexValue
  }

  static let signedIn = CodexValue.object([
    "type": .string("chatgpt"), "email": .string("person@example.com"), "planType": .string("plus"),
  ])
  private var accountValue: CodexValue
  private let loginSuccess: Bool?
  private let loginURL: String
  private let turnNotifications: [CodexNotification]
  private let onRequest: @Sendable (String) -> Void
  private let delayTurnStart: Bool
  private var turnStartWaiter: CheckedContinuation<Void, Never>?
  private var observers: [UUID: AsyncThrowingStream<CodexNotification, Error>.Continuation] = [:]
  private(set) var recordedRequests: [Request] = []

  init(
    account: CodexValue = MockCodexTransport.signedIn,
    loginSuccess: Bool? = nil,
    loginURL: String = "https://auth.openai.com/oauth/authorize?example=1",
    turnNotifications: [CodexNotification] = [],
    delayTurnStart: Bool = false,
    onRequest: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    accountValue = account
    self.loginSuccess = loginSuccess
    self.loginURL = loginURL
    self.turnNotifications = turnNotifications
    self.delayTurnStart = delayTurnStart
    self.onRequest = onRequest
  }

  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    recordedRequests.append(Request(method: method, params: params))
    onRequest(method)
    switch method {
    case "account/read": return .object(["account": accountValue])
    case "account/logout": accountValue = .null; return .object([:])
    case "account/login/start":
      if let loginSuccess {
        emit(CodexNotification(method: "account/login/completed", params: .object([
          "loginId": .string("login-one"), "success": .bool(loginSuccess), "error": .string("Login denied"),
        ])))
      }
      return .object(["type": .string("chatgpt"), "loginId": .string("login-one"), "authUrl": .string(loginURL)])
    case "model/list":
      let secondPage = params["cursor"].string != nil
      return .object([
        "data": .array([.object([
          "id": .string("opaque-id"), "model": .string(secondPage ? "model-two" : "model-one"),
          "displayName": .string(secondPage ? "Second model" : "First model"), "hidden": .bool(false),
        ]), .object(["model": .string("hidden"), "displayName": .string("Hidden"), "hidden": .bool(true)])]),
        "nextCursor": secondPage ? .null : .string("page-two"),
      ])
    case "thread/start": return .object(["thread": .object(["id": .string("thread-one")])])
    case "turn/start":
      if delayTurnStart { await withCheckedContinuation { turnStartWaiter = $0 } }
      for notification in turnNotifications { emit(notification) }
      return .object(["turn": .object(["id": .string("turn-one")])])
    default: return .object([:])
    }
  }

  func releaseTurnStart() {
    turnStartWaiter?.resume()
    turnStartWaiter = nil
  }

  func notifications() -> CodexNotificationSubscription {
    let id = UUID()
    let stream = AsyncThrowingStream<CodexNotification, Error> { continuation in
      observers[id] = continuation
      continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    }
    return CodexNotificationSubscription(stream: stream, cancel: { [weak self] in
      await self?.removeObserver(id)
    })
  }

  private func emit(_ notification: CodexNotification) {
    for continuation in observers.values { continuation.yield(notification) }
  }

  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.finish() }
}

private struct CodexTestCredentials: CloudCredentialStore {
  func apiKey(for provider: CloudProviderID) throws -> String? { provider == .chatGPT ? nil : "unused-api-key" }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {}
  func removeAPIKey(for provider: CloudProviderID) throws { XCTFail("Subscription sign-out must not remove API keys") }
}

private struct NoNetworkTransport: CloudNetworkTransport {
  func data(for request: URLRequest) async throws -> CloudDataResponse {
    XCTFail("Subscription mode must not use an API-key transport")
    throw CodexError.invalidResponse
  }
  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    XCTFail("Subscription mode must not use an API-key transport")
    return AsyncThrowingStream { $0.finish(throwing: CodexError.invalidResponse) }
  }
}
