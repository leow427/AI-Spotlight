import Foundation
import XCTest
@testable import PrimaryAgent

final class LocalInferenceTests: XCTestCase {
  func testInstallationStoreCopiesGGUFAndRestoresSelection() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "LocalModelInstallationStoreTests-\(UUID().uuidString)")
    let sourceURL = root.appending(path: "source.gguf")
    let modelsURL = root.appending(path: "models", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("GGUF fixture".utf8).write(to: sourceURL)

    let store = LocalModelInstallationStore(modelsDirectory: modelsURL)
    let installed = try store.install(
      LocalModel(id: "Fixture Model", displayName: "Fixture", fileURL: sourceURL)
    )

    XCTAssertEqual(installed.displayName, "Fixture")
    XCTAssertEqual(installed.fileURL.pathExtension, "gguf")
    XCTAssertEqual(installed.fileURL.deletingLastPathComponent(), modelsURL)
    XCTAssertEqual(try Data(contentsOf: installed.fileURL), Data("GGUF fixture".utf8))
    XCTAssertEqual(store.installedModel(), installed)

    try Data("replacement fixture".utf8).write(to: sourceURL)
    let replacement = try store.install(
      LocalModel(id: "Fixture Model", displayName: "Replacement", fileURL: sourceURL)
    )
    XCTAssertEqual(
      try Data(contentsOf: replacement.fileURL),
      Data("replacement fixture".utf8)
    )
    XCTAssertNotEqual(replacement.fileURL, installed.fileURL)
    XCTAssertEqual(store.installedModels().count, 1)
    XCTAssertEqual(store.installedModel()?.displayName, "Replacement")

    let secondSourceURL = root.appending(path: "second.gguf")
    try Data("second fixture".utf8).write(to: secondSourceURL)
    let secondInstalled = try store.install(
      LocalModel(id: "Second Model", displayName: "Second", fileURL: secondSourceURL)
    )
    XCTAssertEqual(store.installedModels().map(\.id), ["Fixture Model", "Second Model"])

    try store.selectModel(id: installed.id)
    XCTAssertEqual(store.installedModel()?.id, installed.id)
    XCTAssertEqual(secondInstalled.id, "Second Model")
  }

  func testInstallationStoreRejectsNonGGUFFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "LocalModelInstallationStoreTests-\(UUID().uuidString)")
    let sourceURL = root.appending(path: "model.txt")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not a model".utf8).write(to: sourceURL)

    let store = LocalModelInstallationStore(
      modelsDirectory: root.appending(path: "models")
    )

    XCTAssertThrowsError(
      try store.install(LocalModel(id: "bad", displayName: "Bad", fileURL: sourceURL))
    ) { error in
      XCTAssertEqual(error as? LocalInferenceError, .invalidModelFile)
    }
  }

  @MainActor
  func testViewModelStreamsPartialMarkdownIntoAssistantMessage() async {
    let installedModel = fixtureModel()
    let engine = MockLocalModelEngine(
      installedModel: installedModel,
      stream: { _ in
        AsyncThrowingStream { continuation in
          continuation.yield("**Local")
          continuation.yield(" response**")
          continuation.finish()
        }
      }
    )
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    await viewModel.refreshInstalledModel()

    viewModel.submit("Hello")
    await waitUntil { viewModel.state == .idle && viewModel.messages.count == 2 }

    XCTAssertEqual(viewModel.messages[0].content, "Hello")
    XCTAssertEqual(viewModel.messages[1].content, "**Local response**")
    XCTAssertEqual(engine.requests.map(\.prompt), ["Hello"])
  }

  @MainActor
  func testViewModelInstallsSelectedModelThroughEngine() async {
    let engine = MockLocalModelEngine()
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    let selectedURL = URL(fileURLWithPath: "/tmp/My Model.gguf")

    viewModel.installModel(from: selectedURL)
    await waitUntil { viewModel.installedModel != nil && viewModel.state == .idle }

    XCTAssertEqual(viewModel.installedModel?.displayName, "My Model")
    XCTAssertEqual(viewModel.installedModel?.fileURL, selectedURL)
  }

  @MainActor
  func testViewModelPreservesPartialOutputWhenStreamFails() async {
    let engine = MockLocalModelEngine(
      installedModel: fixtureModel(),
      stream: { _ in
        AsyncThrowingStream { continuation in
          continuation.yield("Partial")
          continuation.finish(throwing: MockError.failed)
        }
      }
    )
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())

    viewModel.submit("Hello")
    await waitUntil {
      if case .failed = viewModel.state { return true }
      return false
    }

    XCTAssertEqual(viewModel.messages.last?.content, "Partial")
    XCTAssertEqual(viewModel.state, .failed("The mocked stream failed."))
  }

  @MainActor
  func testStopStreamingCancelsTheUnderlyingStream() async {
    let cancellation = CancellationProbe()
    let engine = MockLocalModelEngine(
      installedModel: fixtureModel(),
      stream: { _ in
        AsyncThrowingStream { continuation in
          continuation.yield("First")
          continuation.onTermination = { @Sendable _ in
            cancellation.record()
          }
        }
      }
    )
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())

    viewModel.submit("Hello")
    await waitUntil { viewModel.messages.last?.content == "First" }
    viewModel.stopStreaming()
    await waitUntil { cancellation.wasRecorded }

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertEqual(viewModel.messages.last?.content, "First")
  }

  @MainActor
  func testIdlePolicyUnloadsModelWithoutPollingDelays() async {
    let engine = MockLocalModelEngine(installedModel: fixtureModel())
    let viewModel = LocalChatViewModel(
      engine: engine,
      sessionStore: makeSessionStore(),
      idleUnloadDelay: .seconds(300),
      sleep: { _ in }
    )

    viewModel.applicationBecameInactive()
    await waitUntil { engine.unloadCount == 1 }

    XCTAssertEqual(engine.unloadCount, 1)
  }

  func testLlamaEngineDoesNotLoadWithoutAnInstalledModel() async {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "LlamaCPPModelEngineTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = LlamaCPPModelEngine(
      installationStore: LocalModelInstallationStore(modelsDirectory: root)
    )

    do {
      for try await _ in engine.stream(LocalModelRequest(prompt: "Hello")) {}
      XCTFail("Expected the stream to reject a missing local model")
    } catch {
      XCTAssertEqual(error as? LocalInferenceError, .noModelInstalled)
    }
  }

  @MainActor
  func testLocalFollowupReceivesHistoryAndSwitchingChatsDoesNotLeakIt() async throws {
    let engine = MockLocalModelEngine(installedModel: fixtureModel(), stream: { _ in
      AsyncThrowingStream { $0.yield("response"); $0.finish() }
    })
    let store = makeSessionStore()
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: store)
    viewModel.submit("First question")
    await waitUntil { viewModel.state == .idle && viewModel.messages.count == 2 }
    let firstSession = try XCTUnwrap(viewModel.selectedSessionID)
    viewModel.submit("Second question")
    await waitUntil { viewModel.state == .idle && viewModel.messages.count == 4 }
    XCTAssertEqual(engine.requests[1].messages.map(\.content), ["First question", "response", "Second question"])
    XCTAssertEqual(engine.requests[1].messages.map(\.role), [.user, .assistant, .user])
    viewModel.newChat()
    viewModel.submit("Separate question")
    await waitUntil { viewModel.state == .idle && viewModel.messages.count == 2 }
    XCTAssertEqual(engine.requests[2].messages.map(\.content), ["Separate question"])
    viewModel.selectSession(id: firstSession)
    viewModel.submit("Third question")
    await waitUntil { viewModel.state == .idle && viewModel.messages.count == 6 }
    XCTAssertEqual(engine.requests[3].messages.map(\.content), ["First question", "response", "Second question", "response", "Third question"])
    let saved = try XCTUnwrap(store.load().first { $0.id == firstSession }?.messages)
    XCTAssertEqual(saved.map(\.id), viewModel.messages.map(\.id))
    XCTAssertEqual(saved.map(\.role), viewModel.messages.map(\.role))
    XCTAssertEqual(saved.map(\.content), viewModel.messages.map(\.content))
  }

  @MainActor
  func testLocalTrimmingDoesNotDeletePersistedHistory() async throws {
    let store = makeSessionStore()
    let original = [
      ChatMessage(role: .user, content: String(repeating: "old", count: 2_000)),
      ChatMessage(role: .assistant, content: "old reply"),
      ChatMessage(role: .user, content: "recent"),
      ChatMessage(role: .assistant, content: "recent reply"),
    ]
    try store.save([ChatSession(messages: original)])
    let persistedOriginal = store.load()[0].messages
    let engine = MockLocalModelEngine(installedModel: fixtureModel())
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: store)
    viewModel.submit("current")
    await waitUntil { viewModel.state == .idle && engine.requests.count == 1 }
    XCTAssertEqual(engine.requests[0].messages.map(\.content), ["recent", "recent reply", "current"])
    XCTAssertEqual(Array(store.load()[0].messages.prefix(4)), persistedOriginal)
    XCTAssertEqual(store.load()[0].messages.count, 6)
    XCTAssertNotNil(viewModel.contextNotice)
  }

  @MainActor
  func testContextRejectionPreservesDraftAndDoesNotPersistOrGenerate() async {
    let engine = MockLocalModelEngine(installedModel: fixtureModel())
    let store = makeSessionStore()
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: store)
    let original = "  " + String(repeating: "x", count: 40_000) + "\n"
    var draft = original
    viewModel.submit(draft, onAccepted: { draft = "" })
    await waitUntil { if case .failed = viewModel.state { return true }; return false }
    XCTAssertEqual(draft, original)
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertTrue(store.load().isEmpty)
    for provider in CloudProviderID.allCases {
      viewModel.submitCloud(draft, provider: provider, modelID: "manual", onAccepted: { draft = "" })
      XCTAssertEqual(draft, original)
      XCTAssertTrue(viewModel.messages.isEmpty)
      XCTAssertTrue(store.load().isEmpty)
      guard case .failed(let message) = viewModel.state else { return XCTFail("Expected context rejection") }
      XCTAssertTrue(message.contains("Shorten"))
    }
  }

  @MainActor
  func testAcceptedLocalRequestClearsDraftOnlyAfterPreparation() async {
    let engine = MockLocalModelEngine(installedModel: fixtureModel())
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    var draft = "Hello"
    viewModel.submit(draft, onAccepted: { draft = "" })
    XCTAssertEqual(draft, "Hello")
    await waitUntil { viewModel.state == .idle && engine.requests.count == 1 }
    XCTAssertEqual(draft, "")
  }

  @MainActor
  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    iterations: Int = 1_000
  ) async {
    for _ in 0..<iterations {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Condition was not satisfied")
  }

  private func fixtureModel() -> LocalModel {
    LocalModel(
      id: "fixture",
      displayName: "Fixture",
      fileURL: URL(fileURLWithPath: "/tmp/fixture.gguf")
    )
  }

  private func makeSessionStore() -> ChatSessionStore {
    ChatSessionStore(
      applicationSupportDirectory: FileManager.default.temporaryDirectory
        .appending(path: "LocalInferenceTests-\(UUID().uuidString)")
    )
  }
}

private enum MockError: LocalizedError {
  case failed

  var errorDescription: String? { "The mocked stream failed." }
}

private final class MockLocalModelEngine: LocalModelEngine, @unchecked Sendable {
  typealias StreamFactory = @Sendable (LocalModelRequest) -> AsyncThrowingStream<String, Error>

  private let lock = NSLock()
  private let streamFactory: StreamFactory
  private var storedModel: LocalModel?
  private var storedRequests: [LocalModelRequest] = []
  private var storedUnloadCount = 0

  init(
    installedModel: LocalModel? = nil,
    stream: @escaping StreamFactory = { _ in
      AsyncThrowingStream { $0.finish() }
    }
  ) {
    storedModel = installedModel
    streamFactory = stream
  }

  var requests: [LocalModelRequest] {
    access { storedRequests }
  }

  var unloadCount: Int {
    access { storedUnloadCount }
  }

  func install(_ model: LocalModel) async throws {
    access { storedModel = model }
  }

  func installedModel() async -> LocalModel? {
    access { storedModel }
  }

  func installedModels() async -> [LocalModel] {
    access { storedModel.map { [$0] } ?? [] }
  }

  func selectModel(id: String) async throws {
    guard access({ storedModel?.id == id }) else {
      throw LocalInferenceError.unknownInstalledModel
    }
  }

  func download(
    _ model: LocalModelDescriptor,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel {
    let localModel = LocalModel(
      id: model.id,
      displayName: model.displayName,
      fileURL: URL(fileURLWithPath: "/tmp/\(model.id).gguf")
    )
    access { storedModel = localModel }
    await progress(ModelDownloadProgress(
      receivedByteCount: model.expectedByteCount,
      expectedByteCount: model.expectedByteCount
    ))
    return localModel
  }

  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    access { storedRequests.append(request) }
    return streamFactory(request)
  }

  func unload() async {
    access { storedUnloadCount += 1 }
  }

  private func access<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

private final class CancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded = false

  var wasRecorded: Bool {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func record() {
    lock.lock()
    recorded = true
    lock.unlock()
  }
}
