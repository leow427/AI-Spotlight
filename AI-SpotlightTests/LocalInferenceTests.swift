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
    XCTAssertEqual(installed.fileURL.lastPathComponent, "Fixture-Model.gguf")
    XCTAssertEqual(try Data(contentsOf: installed.fileURL), Data("GGUF fixture".utf8))
    XCTAssertEqual(store.installedModel(), installed)

    try Data("replacement fixture".utf8).write(to: sourceURL)
    _ = try store.install(
      LocalModel(id: "Fixture Model", displayName: "Replacement", fileURL: sourceURL)
    )
    XCTAssertEqual(
      try Data(contentsOf: installed.fileURL),
      Data("replacement fixture".utf8)
    )
    XCTAssertEqual(store.installedModel()?.displayName, "Replacement")
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
    let viewModel = LocalChatViewModel(engine: engine)
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
    let viewModel = LocalChatViewModel(engine: engine)
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
    let viewModel = LocalChatViewModel(engine: engine)

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
    let viewModel = LocalChatViewModel(engine: engine)

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
