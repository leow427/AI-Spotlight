import Combine
import Foundation
import XCTest
@testable import PrimaryAgent

@MainActor
final class RequestLifecycleTests: XCTestCase {
  private enum QueuedEnding: CaseIterable {
    case token, failure, completion
  }

  func testLocalReplacementIgnoresQueuedTokensFailuresAndCompletion() async throws {
    for ending in QueuedEnding.allCases {
      let first = ControlledStream<String>()
      let second = ControlledStream<String>()
      let engine = LifecycleLocalEngine(streams: [first, second])
      let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeStore())
      await viewModel.refreshInstalledModel()
      viewModel.submit("A")
      await fulfillment(of: [first.started], timeout: 2)
      await receive("A partial", from: first, in: viewModel)
      let firstSession = try XCTUnwrap(viewModel.selectedSessionID)
      let firstID = try XCTUnwrap(viewModel.activeRequest?.id)

      // No suspension between queuing A's event, Stop, and starting B: A's
      // MainActor consumer cannot process the event until B owns the lifecycle.
      queue(ending, on: first, token: "stale A")
      let oldTask = try XCTUnwrap(viewModel.stopStreaming())
      viewModel.newChat()
      viewModel.submit("B")
      let replacement = try XCTUnwrap(viewModel.activeRequest)
      XCTAssertNotEqual(replacement.id, firstID)
      await oldTask.value
      await fulfillment(of: [second.started], timeout: 2)

      XCTAssertTrue(viewModel.isBusy)
      XCTAssertEqual(viewModel.state, .preparing)
      XCTAssertEqual(viewModel.activeRequest, replacement)
      XCTAssertEqual(replacement.route, Route(mode: .local, providerID: "local", modelID: "fixture", usesNetwork: false))
      XCTAssertEqual(replacement.displayName, "Local · Fixture")
      XCTAssertEqual(viewModel.sessions.first { $0.id == firstSession }?.messages.last?.content, "A partial")
      XCTAssertEqual(viewModel.messages.map(\.content), ["B", ""])
      viewModel.submit("Unintended third request")
      XCTAssertEqual(engine.requests.map(\.prompt), ["A", "B"])

      await receive("B partial", from: second, in: viewModel)
      let newTask = try XCTUnwrap(viewModel.stopStreaming())
      await newTask.value
      await fulfillment(of: [second.cancelled], timeout: 2)
      XCTAssertFalse(viewModel.isBusy)
      XCTAssertNil(viewModel.activeRequest)
      XCTAssertEqual(viewModel.messages.last?.content, "B partial")
    }
  }

  func testCloudReplacementIgnoresQueuedTokensFailuresAndCompletion() async throws {
    for ending in QueuedEnding.allCases {
      let first = ControlledStream<ChatEvent>()
      let second = ControlledStream<ChatEvent>()
      let provider = LifecycleCloudProvider(streams: [first, second])
      let viewModel = LocalChatViewModel(
        engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
      )
      viewModel.submitCloud("A", provider: .chatGPT, modelID: "first-model")
      await fulfillment(of: [first.started], timeout: 2)
      await receive(.token("A partial"), from: first, in: viewModel)
      let sessionID = viewModel.selectedSessionID
      queue(ending, on: first, token: .token("stale A"))
      let oldTask = try XCTUnwrap(viewModel.stopStreaming())
      viewModel.submitCloud("B", provider: .chatGPT, modelID: "second-model")
      let replacement = try XCTUnwrap(viewModel.activeRequest)
      await oldTask.value
      await fulfillment(of: [second.started], timeout: 2)

      XCTAssertTrue(viewModel.isBusy)
      XCTAssertEqual(viewModel.state, .preparing)
      XCTAssertEqual(viewModel.activeRequest, replacement)
      XCTAssertEqual(viewModel.selectedSessionID, sessionID)
      XCTAssertEqual(viewModel.messages.map(\.content), ["A", "A partial", "B", ""])
      XCTAssertEqual(provider.requests.last?.messages.map(\.content), ["A", "A partial", "B"])
      viewModel.submitCloud("Unintended third request", provider: .chatGPT, modelID: "third")
      XCTAssertEqual(provider.requests.count, 2)

      await receive(.token("B partial"), from: second, in: viewModel)
      await viewModel.stopStreaming()?.value
      await fulfillment(of: [second.cancelled], timeout: 2)
      XCTAssertEqual(viewModel.state, .idle)
      XCTAssertNil(viewModel.activeRequest)
      XCTAssertEqual(viewModel.messages.last?.content, "B partial")
    }
  }

  func testLateLocalPreparationCannotAcceptDraftOrMutateReplacement() async throws {
    for fails in [false, true] {
      let gate = PreparationGate()
      let first = LifecycleLocalEngine(prepare: { request in
        await gate.wait()
        if fails { throw LifecycleError.failed }
        return try LifecycleLocalEngine.prepareContext(request)
      })
      let cloud = ControlledStream<ChatEvent>()
      let viewModel = LocalChatViewModel(
        engine: first, cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: [cloud])),
        sessionStore: makeStore()
      )
      let original = "  A draft\n"
      var draft = original
      viewModel.submit(draft, onAccepted: { draft = "" })
      await fulfillment(of: [gate.entered], timeout: 2)
      let oldTask = try XCTUnwrap(viewModel.stopStreaming())
      viewModel.newChat()
      viewModel.submitCloud("B", provider: .chatGPT, modelID: "replacement")
      let active = viewModel.activeRequest
      await fulfillment(of: [cloud.started], timeout: 2)
      await gate.release()
      await oldTask.value

      XCTAssertEqual(draft, original)
      XCTAssertEqual(viewModel.messages.map(\.content), ["B", ""])
      XCTAssertTrue(first.requests.isEmpty)
      XCTAssertTrue(viewModel.isBusy)
      XCTAssertEqual(viewModel.activeRequest, active)
      await viewModel.stopStreaming()?.value
      await fulfillment(of: [cloud.cancelled], timeout: 2)
    }
  }

  func testStopBeforeCloudTaskStartsDoesNotLaunchProducer() async throws {
    let provider = LifecycleCloudProvider()
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
    )
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "model")
    let task = try XCTUnwrap(viewModel.stopStreaming())
    viewModel.newChat()
    await task.value
    XCTAssertTrue(provider.requests.isEmpty)
    XCTAssertTrue(viewModel.messages.isEmpty)
    XCTAssertFalse(viewModel.isBusy)
  }

  func testAcceptanceCallbackCanReplaceCloudRequestWithoutLosingNewHandle() async throws {
    let stream = ControlledStream<ChatEvent>()
    let provider = LifecycleCloudProvider(streams: [stream])
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
    )
    var oldTask: Task<Void, Never>?
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "first", onAccepted: {
      oldTask = viewModel.stopStreaming()
      viewModel.newChat()
      viewModel.submitCloud("B", provider: .chatGPT, modelID: "replacement")
    })
    await oldTask?.value
    await fulfillment(of: [stream.started], timeout: 2)
    XCTAssertEqual(provider.requests.map { $0.route.modelID }, ["replacement"])
    XCTAssertEqual(viewModel.activeRequest?.route.modelID, "replacement")
    XCTAssertTrue(viewModel.isBusy)
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [stream.cancelled], timeout: 2)
  }

  func testAutoRejectionsPreserveOriginalDraftWithoutStartingAnyProducer() async {
    let engine = LifecycleLocalEngine()
    let provider = LifecycleCloudProvider()
    let viewModel = LocalChatViewModel(
      engine: engine, cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
    )
    await viewModel.refreshInstalledModel()
    let cloud = AutoRouter.CloudConfiguration(provider: .chatGPT, modelID: "manual")
    viewModel.submitCloud(String(repeating: "x", count: 40_000), provider: .chatGPT, modelID: "manual")
    guard case .failed = viewModel.state else { return XCTFail("Expected initial context rejection") }
    for original in ["  Search the web for today's news\n", "  " + String(repeating: "x", count: 40_000) + "\n"] {
      var draft = original
      viewModel.submitAuto(draft, cloud: cloud, onAccepted: { draft = "" })
      XCTAssertEqual(draft, original)
      XCTAssertNil(viewModel.autoRouteDecision?.route)
      XCTAssertNotNil(viewModel.autoRouteDecision?.limitation)
      XCTAssertNil(viewModel.activeRequest)
      XCTAssertTrue(viewModel.messages.isEmpty)
      XCTAssertFalse(viewModel.isBusy)
      XCTAssertEqual(viewModel.state, .idle, "An earlier error must not hide the current routing limitation")
    }
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertTrue(provider.requests.isEmpty)
  }

  func testLocalAcceptanceCallbackCanStopBeforeStartingProducer() async {
    let engine = LifecycleLocalEngine()
    let cloud = ControlledStream<ChatEvent>()
    let viewModel = LocalChatViewModel(
      engine: engine, cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: [cloud])), sessionStore: makeStore()
    )
    var oldTask: Task<Void, Never>?
    viewModel.submit("A", onAccepted: {
      oldTask = viewModel.stopStreaming()
      viewModel.newChat()
      viewModel.submitCloud("B", provider: .chatGPT, modelID: "replacement")
    })
    await fulfillment(of: [cloud.started], timeout: 2)
    await oldTask?.value
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertEqual(viewModel.messages.map(\.content), ["B", ""])
    XCTAssertEqual(viewModel.activeRequest?.route.modelID, "replacement")
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [cloud.cancelled], timeout: 2)
  }

  func testDirectAPIReplacementStillCancelsItsOwnNetworkSource() async throws {
    for provider in [CloudProviderID.openAI, .anthropic] {
      let first = ControlledStream<CloudNetworkEvent>()
      let second = ControlledStream<CloudNetworkEvent>()
      let transport = LifecycleNetworkTransport(streams: [first, second])
      let viewModel = LocalChatViewModel(
        engine: LifecycleLocalEngine(),
        cloudProviders: CloudProviderRegistry(credentialStore: LifecycleCredentials(), transport: transport),
        sessionStore: makeStore()
      )
      viewModel.submitCloud("A", provider: provider, modelID: "model-a")
      await fulfillment(of: [first.started], timeout: 2)
      first.continuation.yield(.response(statusCode: 200))
      await receive(apiToken("A partial", provider: provider), from: first, in: viewModel)
      first.continuation.yield(apiToken("stale A", provider: provider))
      let oldTask = try XCTUnwrap(viewModel.stopStreaming())
      viewModel.newChat()
      viewModel.submitCloud("B", provider: provider, modelID: "model-b")
      let active = viewModel.activeRequest
      await oldTask.value
      await fulfillment(of: [first.cancelled, second.started], timeout: 2)
      XCTAssertEqual(viewModel.activeRequest, active)
      XCTAssertTrue(viewModel.isBusy)
      second.continuation.yield(.response(statusCode: 200))
      await receive(apiToken("B partial", provider: provider), from: second, in: viewModel)
      XCTAssertEqual(viewModel.messages.map(\.content), ["B", "B partial"])
      await viewModel.stopStreaming()?.value
      await fulfillment(of: [second.cancelled], timeout: 2)
      XCTAssertFalse(viewModel.isBusy)
    }
  }

  func testCurrentCompletionReleasesActiveRouteAndAllowsNextRequest() async {
    let first = ControlledStream<ChatEvent>()
    let second = ControlledStream<ChatEvent>()
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: [first, second])),
      sessionStore: makeStore()
    )
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "first")
    await fulfillment(of: [first.started], timeout: 2)
    let completed = expectation(description: "Request completed")
    let observation = viewModel.$state.sink { if $0 == .idle { completed.fulfill() } }
    first.continuation.yield(.token("Answer"))
    first.continuation.yield(.completed)
    first.continuation.finish()
    await fulfillment(of: [completed], timeout: 2)
    observation.cancel()
    XCTAssertNil(viewModel.activeRequest)
    XCTAssertFalse(viewModel.isBusy)
    XCTAssertEqual(viewModel.messages.last?.content, "Answer")
    viewModel.submitCloud("B", provider: .chatGPT, modelID: "second")
    await fulfillment(of: [second.started], timeout: 2)
    XCTAssertEqual(viewModel.activeRequest?.route.modelID, "second")
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [second.cancelled], timeout: 2)
  }

  func testActiveCloudFeedbackSurvivesNextModeProviderAndModelChanges() async throws {
    let stream = ControlledStream<ChatEvent>()
    let provider = LifecycleCloudProvider(streams: [stream])
    let credentials = LifecycleCredentials()
    let suite = "RequestLifecycleTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: LifecycleNoNetwork(), cacheDirectory: temporaryDirectory()),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false }
    )
    settings.preferredProvider = .chatGPT
    settings.preferredModelID = "captured-model"
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
    )
    viewModel.submitCloud("A", provider: settings.preferredProvider, modelID: settings.preferredModelID)
    let active = try XCTUnwrap(viewModel.activeRequest)
    XCTAssertEqual(active.displayName, "Cloud · ChatGPT via Codex · captured-model")
    await fulfillment(of: [stream.started], timeout: 2)
    await receive(.token("Partial"), from: stream, in: viewModel)
    // The mode control calls this when the next mode changes. Its decision must
    // not be the source of the active request's route label.
    viewModel.clearAutoRouteDecision()
    settings.preferredProvider = .anthropic
    settings.preferredModelID = "next-model"
    XCTAssertEqual(viewModel.activeRequest, active)
    XCTAssertEqual(viewModel.activeRequest?.displayName, "Cloud · ChatGPT via Codex · captured-model")
    XCTAssertEqual(provider.requests.first?.route, active.route)
    XCTAssertEqual(viewModel.state, .streaming)
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [stream.cancelled], timeout: 2)
    XCTAssertNil(viewModel.activeRequest)
  }

  func testCurrentCloudFailureKeepsPartialOutputAndReleasesOwnership() async {
    let stream = ControlledStream<ChatEvent>()
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: [stream])),
      sessionStore: makeStore()
    )
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "model")
    await fulfillment(of: [stream.started], timeout: 2)
    await receive(.token("Partial"), from: stream, in: viewModel)
    let failed = expectation(description: "Current failure is displayed")
    let observation = viewModel.$state.sink { if case .failed = $0 { failed.fulfill() } }
    stream.continuation.finish(throwing: LifecycleError.failed)
    await fulfillment(of: [failed], timeout: 2)
    observation.cancel()
    XCTAssertEqual(viewModel.state, .failed("Controlled failure"))
    XCTAssertEqual(viewModel.messages.last?.content, "Partial")
    XCTAssertFalse(viewModel.isBusy)
    XCTAssertNil(viewModel.activeRequest)
  }

  func testCodexReplacementRemainsCancellableAfterOldServerCleanup() async throws {
    let transport = LifecycleCodexTransport()
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(),
      cloudProviders: registry(chatGPT: CodexSubscriptionClient(transport: transport)), sessionStore: makeStore()
    )
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "first")
    await fulfillment(of: [transport.firstTurnStarted], timeout: 2)
    let oldTask = try XCTUnwrap(viewModel.stopStreaming())
    viewModel.newChat()
    viewModel.submitCloud("B", provider: .chatGPT, modelID: "second")
    let replacement = viewModel.activeRequest
    await fulfillment(of: [transport.secondTurnStarted], timeout: 2)

    // A's turn/start reply arrives after B has already started. The real Codex
    // client must still interrupt/unsubscribe A without losing B's consumer.
    await transport.releaseFirstTurn()
    await oldTask.value
    await fulfillment(of: [transport.firstUnsubscribed], timeout: 2)
    XCTAssertTrue(viewModel.isBusy)
    XCTAssertEqual(viewModel.activeRequest, replacement)
    let received = expectation(description: "B receives its own Codex token")
    let observation = viewModel.$sessions.dropFirst().prefix(1).sink { _ in received.fulfill() }
    await transport.emitToken("B partial", thread: "thread-2")
    await fulfillment(of: [received], timeout: 2)
    observation.cancel()
    XCTAssertEqual(viewModel.messages.map(\.content), ["B", "B partial"])
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [transport.secondUnsubscribed], timeout: 2)
    let interruptions = await transport.interruptions
    XCTAssertEqual(interruptions.map { $0["threadId"].string }, ["thread-1", "thread-2"])
    XCTAssertEqual(interruptions.map { $0["turnId"].string }, ["turn-thread-1", "turn-thread-2"])
    XCTAssertFalse(viewModel.isBusy)
  }

  func testModelSelectionBlocksSubmissionUntilEngineAndFeedbackAgree() async {
    let gate = PreparationGate()
    let engine = LifecycleLocalEngine(select: { await gate.wait() })
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeStore())
    await viewModel.refreshInstalledModel()
    viewModel.selectModel(id: "fixture")
    XCTAssertTrue(viewModel.isBusy)
    await fulfillment(of: [gate.entered], timeout: 2)
    var draft = "Keep while selecting"
    viewModel.submit(draft, onAccepted: { draft = "" })
    XCTAssertEqual(draft, "Keep while selecting")
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertNil(viewModel.stopStreaming(), "Model selection is not a generation task")
    XCTAssertTrue(viewModel.isBusy)
    let selected = expectation(description: "Model selection completed")
    let observation = viewModel.$state.sink { if $0 == .idle { selected.fulfill() } }
    await gate.release()
    await fulfillment(of: [selected], timeout: 2)
    observation.cancel()
    XCTAssertFalse(viewModel.isBusy)
    XCTAssertEqual(viewModel.installedModel?.id, "fixture")
  }

  func testPersistenceFailureCannotAllowOverlappingGenerationOrDisableStop() async throws {
    let root = temporaryDirectory()
    try Data("Not a directory".utf8).write(to: root)
    let stream = ControlledStream<String>()
    let engine = LifecycleLocalEngine(streams: [stream])
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    viewModel.submit("A")
    await fulfillment(of: [stream.started], timeout: 2)
    XCTAssertEqual(viewModel.activeRequest?.route.modelID, "fixture", "Capture the engine's model even before library refresh")
    await receive("Partial", from: stream, in: viewModel)
    guard case .failed(let message) = viewModel.state else { return XCTFail("Expected persistence failure") }
    XCTAssertTrue(message.contains("Unable to save chats"))
    XCTAssertTrue(viewModel.isBusy)
    viewModel.submit("B")
    XCTAssertEqual(engine.requests.map(\.prompt), ["A"])
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [stream.cancelled], timeout: 2)
    XCTAssertFalse(viewModel.isBusy)
  }

  private func queue<Element>(_ ending: QueuedEnding, on stream: ControlledStream<Element>, token: Element) {
    switch ending {
    case .token: stream.continuation.yield(token)
    case .failure: stream.continuation.finish(throwing: LifecycleError.failed)
    case .completion: stream.continuation.finish()
    }
  }

  private func apiToken(_ text: String, provider: CloudProviderID) -> CloudNetworkEvent {
    let payload = provider == .openAI
      ? "{\"type\":\"response.output_text.delta\",\"delta\":\"\(text)\"}"
      : "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}"
    return .data(Data("data: \(payload)\n\n".utf8))
  }

  private func receive<Element>(_ token: Element, from stream: ControlledStream<Element>, in viewModel: LocalChatViewModel) async {
    let received = expectation(description: "Token persisted")
    let observation = viewModel.$sessions.dropFirst().prefix(1).sink { _ in received.fulfill() }
    stream.continuation.yield(token)
    await fulfillment(of: [received], timeout: 2)
    observation.cancel()
  }

  private func registry(chatGPT: any ChatProvider) -> CloudProviderRegistry {
    CloudProviderRegistry(credentialStore: LifecycleCredentials(), transport: LifecycleNoNetwork(), chatGPT: chatGPT)
  }

  private func makeStore() -> ChatSessionStore {
    ChatSessionStore(applicationSupportDirectory: temporaryDirectory())
  }

  private func temporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "RequestLifecycleTests-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}

private enum LifecycleError: LocalizedError {
  case failed
  var errorDescription: String? { "Controlled failure" }
}

private final class ControlledStream<Element: Sendable>: Sendable {
  let stream: AsyncThrowingStream<Element, Error>
  let continuation: AsyncThrowingStream<Element, Error>.Continuation
  let started = XCTestExpectation(description: "Producer started")
  let cancelled = XCTestExpectation(description: "Producer cancelled")

  init() {
    (stream, continuation) = AsyncThrowingStream.makeStream()
    continuation.onTermination = { [cancelled] reason in
      if case .cancelled = reason { cancelled.fulfill() }
    }
  }
}

private final class LifecycleLocalEngine: LocalModelEngine, @unchecked Sendable {
  private let lock = NSLock()
  private let streams: [ControlledStream<String>]
  private let preparation: @Sendable (LocalModelRequest) async throws -> PreparedConversation
  private let selection: @Sendable () async -> Void
  private var storedRequests: [LocalModelRequest] = []

  init(
    streams: [ControlledStream<String>] = [],
    prepare: @escaping @Sendable (LocalModelRequest) async throws -> PreparedConversation = { try prepareContext($0) },
    select: @escaping @Sendable () async -> Void = {}
  ) {
    self.streams = streams
    preparation = prepare
    selection = select
  }

  var requests: [LocalModelRequest] { lock.withLock { storedRequests } }
  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? {
    LocalModel(id: "fixture", displayName: "Fixture", fileURL: URL(fileURLWithPath: "/tmp/fixture.gguf"))
  }
  func installedModels() async -> [LocalModel] { await installedModel().map { [$0] } ?? [] }
  func selectModel(id: String) async throws { await selection() }
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    throw LifecycleError.failed
  }
  func unload() async {}
  func prepare(_ request: LocalModelRequest) async throws -> PreparedConversation { try await preparation(request) }
  static func prepareContext(_ request: LocalModelRequest) throws -> PreparedConversation {
    try ChatContextPreparer.prepare(request.messages,
      budget: ContextBudget(contextWindow: 4_096, outputTokens: request.maximumTokenCount, overheadTokens: 256),
      countTokens: { $0.reduce(0) { $0 + $1.content.utf8.count + 32 } })
  }

  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    let index = lock.withLock { storedRequests.append(request); return storedRequests.count - 1 }
    guard streams.indices.contains(index) else {
      XCTFail("Unexpected local producer")
      return AsyncThrowingStream { $0.finish() }
    }
    streams[index].started.fulfill()
    return streams[index].stream
  }
}

private final class LifecycleCloudProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private let streams: [ControlledStream<ChatEvent>]
  private var storedRequests: [ChatRequest] = []

  init(streams: [ControlledStream<ChatEvent>] = []) { self.streams = streams }
  var requests: [ChatRequest] { lock.withLock { storedRequests } }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    let index = lock.withLock { storedRequests.append(request); return storedRequests.count - 1 }
    guard streams.indices.contains(index) else {
      XCTFail("Unexpected cloud producer")
      return AsyncThrowingStream { $0.finish() }
    }
    streams[index].started.fulfill()
    return streams[index].stream
  }
}

private actor PreparationGate {
  nonisolated let entered = XCTestExpectation(description: "Preparation suspended")
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered.fulfill()
    }
  }
  func release() { continuation?.resume(); continuation = nil }
}

private struct LifecycleCredentials: CloudCredentialStore {
  func apiKey(for provider: CloudProviderID) throws -> String? { "test-key" }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {}
  func removeAPIKey(for provider: CloudProviderID) throws {}
}

private struct LifecycleNoNetwork: CloudNetworkTransport {
  func data(for request: URLRequest) async throws -> CloudDataResponse {
    XCTFail("Unexpected network request")
    throw LifecycleError.failed
  }
  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    XCTFail("Unexpected network stream")
    return AsyncThrowingStream { $0.finish(throwing: LifecycleError.failed) }
  }
}

private actor LifecycleCodexTransport: CodexRPCTransport {
  nonisolated let firstTurnStarted = XCTestExpectation(description: "A turn/start pending")
  nonisolated let secondTurnStarted = XCTestExpectation(description: "B turn started")
  nonisolated let firstUnsubscribed = XCTestExpectation(description: "A server cleanup finished")
  nonisolated let secondUnsubscribed = XCTestExpectation(description: "B server cleanup finished")
  private var threadCount = 0
  private var firstTurnReply: CheckedContinuation<Void, Never>?
  private var observers: [UUID: AsyncThrowingStream<CodexNotification, Error>.Continuation] = [:]
  private(set) var interruptions: [CodexValue] = []

  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    switch method {
    case "account/read":
      return .object(["account": .object(["type": .string("chatgpt"), "planType": .string("plus")])])
    case "thread/start":
      threadCount += 1
      return .object(["thread": .object(["id": .string("thread-\(threadCount)")])])
    case "turn/start":
      let thread = params["threadId"].string ?? ""
      if thread == "thread-1" {
        await withCheckedContinuation {
          firstTurnReply = $0
          firstTurnStarted.fulfill()
        }
      } else { secondTurnStarted.fulfill() }
      return .object(["turn": .object(["id": .string("turn-\(thread)")])])
    case "turn/interrupt": interruptions.append(params)
    case "thread/unsubscribe":
      if params["threadId"].string == "thread-1" { firstUnsubscribed.fulfill() }
      else { secondUnsubscribed.fulfill() }
    default: XCTFail("Unexpected Codex method: \(method)")
    }
    return .object([:])
  }

  func releaseFirstTurn() { firstTurnReply?.resume(); firstTurnReply = nil }

  func notifications() -> CodexNotificationSubscription {
    let id = UUID()
    let (stream, continuation) = AsyncThrowingStream<CodexNotification, Error>.makeStream()
    observers[id] = continuation
    return CodexNotificationSubscription(stream: stream, cancel: { [weak self] in await self?.removeObserver(id) })
  }

  func emitToken(_ token: String, thread: String) {
    for continuation in observers.values {
      continuation.yield(CodexNotification(method: "item/agentMessage/delta", params: .object([
        "threadId": .string(thread), "turnId": .string("turn-\(thread)"), "delta": .string(token),
      ])))
    }
  }

  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.finish() }
}

private final class LifecycleNetworkTransport: CloudNetworkTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let streams: [ControlledStream<CloudNetworkEvent>]
  private var count = 0
  init(streams: [ControlledStream<CloudNetworkEvent>]) { self.streams = streams }

  func data(for request: URLRequest) async throws -> CloudDataResponse { throw LifecycleError.failed }
  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    let index = lock.withLock { defer { count += 1 }; return count }
    guard streams.indices.contains(index) else {
      XCTFail("Unexpected network source")
      return AsyncThrowingStream { $0.finish() }
    }
    streams[index].started.fulfill()
    return streams[index].stream
  }
}
