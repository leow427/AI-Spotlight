import AppKit
import Combine
import XCTest
@testable import PrimaryAgent

@MainActor
final class ScreenPipelineTests: XCTestCase {
  private let ocr = "let answer_count = values.count\nprint(answer_count)\nerror: cannot find variable in scope"

  func testSlashScreenCodeAutoSubmissionUsesOCRAndPersistsOnlyThePrompt() async throws {
    let fixture = try makeFixture()
    let screen = ScreenComposerCoordinator(captureService: PipelineCapture(), ocrService: PipelineOCR(text: ocr))
    screen.draft = "/screen what is the answer to this piece of code?"
    let automatic = await screen.capture(submittedCommand: true)
    XCTAssertEqual(automatic, "what is the answer to this piece of code?")
    let attachment = try XCTUnwrap(screen.attachment)
    await fixture.chat.refreshInstalledModel()
    let done = finished(fixture.chat)
    fixture.chat.submitScreen(screen.draft, attachment: attachment, decision: .text(fixture.text.screenModel), selectedMode: .local,
      cloudUploadAllowed: { false }) { screen.clearDraft() }
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    let requests = await fixture.engine.requests
    XCTAssertTrue(requests.last?.prompt.contains(ocr) == true)
    XCTAssertTrue(requests.last?.prompt.contains("untrusted source content") == true)
    XCTAssertTrue(fixture.cloud.requests.isEmpty)
    XCTAssertEqual(fixture.chat.messages.first?.content, automatic)
    XCTAssertFalse(fixture.store.load().flatMap(\.messages).contains { $0.content.contains("Text extracted locally") })
    XCTAssertNil(screen.attachment)
    XCTAssertEqual(screen.draft, "")
    XCTAssertNotNil(fixture.chat.messages.first?.imagePreview)
    XCTAssertNil(fixture.chat.messages.last?.imagePreview)
    XCTAssertNil(fixture.store.load().first?.messages.first?.imagePreview)
    let preview = fixture.chat.messages.first?.imagePreview
    let sessionID = try XCTUnwrap(fixture.chat.selectedSessionID)
    fixture.chat.newChat()
    fixture.chat.selectSession(id: sessionID)
    XCTAssertEqual(fixture.chat.messages.first?.imagePreview, preview)
  }

  func testCloudOCRDoesNotAttachPixelsWhenUploadsAreDisabled() async throws {
    let fixture = try makeFixture()
    let attachment = try attachment()
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    let done = finished(fixture.chat)
    fixture.chat.submitScreen("explain this code", attachment: attachment, decision: .text(model), selectedMode: .cloud, cloudUploadAllowed: { false })
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    let request = try XCTUnwrap(fixture.cloud.requests.first)
    XCTAssertNil(request.image)
    XCTAssertFalse(request.allowsCloudImages)
    XCTAssertTrue(request.messages.last?.content.contains(ocr) == true)
    XCTAssertEqual(fixture.store.load().first?.messages.first?.content, "explain this code")
  }

  func testCloudVisionUsesResizedJPEGAndExplicitPermission() async throws {
    let fixture = try makeFixture()
    let attachment = try attachment()
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    let done = finished(fixture.chat)
    fixture.chat.submitScreen("describe the diagram", attachment: attachment, decision: .vision(model), selectedMode: .auto, cloudUploadAllowed: { true })
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    let request = try XCTUnwrap(fixture.cloud.requests.first)
    XCTAssertTrue(request.allowsCloudImages)
    XCTAssertEqual(request.image?.mimeType, "image/jpeg")
    XCTAssertEqual(request.image?.pixelWidth, 1568)
    XCTAssertEqual(request.image?.pixelHeight, 784)
    XCTAssertEqual(fixture.chat.messages.first?.content, "describe the diagram")
    let preview = try XCTUnwrap(fixture.chat.messages.first?.imagePreview)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: preview))
    XCTAssertEqual(bitmap.pixelsWide, 240)
    XCTAssertEqual(bitmap.pixelsHigh, 120)
    XCTAssertNil(request.messages.last?.imagePreview)
    XCTAssertNil(fixture.store.load().first?.messages.first?.imagePreview)
  }

  func testRevokedPermissionPreservesDraftAndNeverCallsProvider() async throws {
    let fixture = try makeFixture()
    let screen = ScreenComposerCoordinator(captureService: PipelineCapture(), ocrService: PipelineOCR(text: ocr))
    screen.draft = "describe this chart"
    _ = await screen.capture()
    let attachment = try XCTUnwrap(screen.attachment)
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    let done = finished(fixture.chat)
    fixture.chat.submitScreen(screen.draft, attachment: attachment, decision: .vision(model), selectedMode: .cloud,
      cloudUploadAllowed: { false }) { screen.clearDraft() }
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    XCTAssertEqual(screen.draft, "describe this chart")
    XCTAssertEqual(screen.attachment?.id, attachment.id)
    XCTAssertTrue(fixture.cloud.requests.isEmpty)
    XCTAssertTrue(fixture.chat.messages.isEmpty)
  }

  func testLocalModeRejectsAnInjectedCloudImageRoute() throws {
    let fixture = try makeFixture()
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    fixture.chat.submitScreen("diagram", attachment: try attachment(), decision: .vision(model), selectedMode: .local, cloudUploadAllowed: { true })
    XCTAssertTrue(fixture.cloud.requests.isEmpty)
    XCTAssertFalse(fixture.chat.isBusy)
    XCTAssertEqual(fixture.chat.state, .failed(ScreenRequestError.cloudUploadNotAllowed.localizedDescription))
  }

  func testOfflineCloudFallsBackToLocalVisionWithoutDuplicateUserTurn() async throws {
    let cloud = PipelineCloud(error: .offline)
    let fixture = try makeFixture(cloud: cloud, withVision: true)
    await fixture.chat.refreshInstalledModel()
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    let done = finished(fixture.chat)
    fixture.chat.submitScreen("describe the chart", attachment: try attachment(), decision: .vision(model), selectedMode: .auto, cloudUploadAllowed: { true })
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    XCTAssertEqual(fixture.vision.imageCount, 1)
    XCTAssertEqual(fixture.chat.messages.filter { $0.role == .user }.count, 1)
    XCTAssertEqual(fixture.chat.screenRouteDecision?.model?.isLocal, true)
    let unloaded = await fixture.engine.unloads
    XCTAssertEqual(unloaded, 1)
  }

  func testStopBeforeFirstTokenKeepsDraftAndIgnoresLateEvents() async throws {
    let started = expectation(description: "Provider started")
    let stream = AsyncThrowingStream<ChatEvent, Error>.makeStream()
    let cloud = PipelineCloud(controlled: stream.stream, started: { started.fulfill() })
    let fixture = try makeFixture(cloud: cloud)
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    var accepted = false
    fixture.chat.submitScreen("diagram", attachment: try attachment(), decision: .vision(model), selectedMode: .cloud,
                              cloudUploadAllowed: { true }) { accepted = true }
    await fulfillment(of: [started], timeout: 3)
    let stopped = fixture.chat.stopStreaming()
    stream.continuation.yield(.token("late"))
    stream.continuation.finish()
    await stopped?.value
    XCTAssertFalse(accepted)
    XCTAssertTrue(fixture.chat.messages.isEmpty)
    XCTAssertNil(fixture.chat.activeRequest)
  }

  func testStoppedScreenRequestCannotAcceptOrFinishItsReplacement() async throws {
    let first = AsyncThrowingStream<ChatEvent, Error>.makeStream()
    let second = AsyncThrowingStream<ChatEvent, Error>.makeStream()
    let firstStarted = expectation(description: "First Screen producer")
    let secondStarted = expectation(description: "Replacement Screen producer")
    let cloud = PipelineCloud(controlledStreams: [first.stream, second.stream], onStarted: { index in
      (index == 0 ? firstStarted : secondStarted).fulfill()
    })
    let fixture = try makeFixture(cloud: cloud)
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    let firstAttachment = try attachment()
    let secondAttachment = try attachment()
    var draft = "first diagram"
    var pending: ScreenAttachment? = firstAttachment
    fixture.chat.submitScreen(draft, attachment: pending, decision: .vision(model), selectedMode: .auto,
      cloudUploadAllowed: { true }) { draft = ""; pending = nil }
    await fulfillment(of: [firstStarted], timeout: 3)
    // Queue the old events without giving its MainActor consumer a chance to
    // process them until the replacement owns the request and composer.
    first.continuation.yield(.token("stale first answer"))
    first.continuation.yield(.completed)
    first.continuation.finish()
    let oldTask = try XCTUnwrap(fixture.chat.stopStreaming())
    draft = "second diagram"
    pending = secondAttachment
    fixture.chat.submitScreen(draft, attachment: pending, decision: .vision(model), selectedMode: .auto,
      cloudUploadAllowed: { true }) { draft = ""; pending = nil }
    let replacement = fixture.chat.activeRequest
    await oldTask.value
    await fulfillment(of: [secondStarted], timeout: 3)
    XCTAssertEqual(draft, "second diagram")
    XCTAssertEqual(pending?.id, secondAttachment.id)
    XCTAssertEqual(fixture.chat.activeRequest, replacement)
    XCTAssertTrue(fixture.chat.isBusy)
    XCTAssertTrue(fixture.chat.messages.isEmpty)
    let done = finished(fixture.chat)
    second.continuation.yield(.token("second answer"))
    second.continuation.yield(.completed)
    second.continuation.finish()
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    XCTAssertEqual(cloud.requests.count, 2)
    XCTAssertEqual(fixture.chat.messages.map(\.content), ["second diagram", "second answer"])
    XCTAssertEqual(draft, "")
    XCTAssertNil(pending)
    XCTAssertNil(fixture.chat.activeRequest)
    XCTAssertFalse(fixture.chat.isBusy)
  }

  private func finished(_ chat: LocalChatViewModel) -> (expectation: XCTestExpectation, token: AnyCancellable) {
    let expectation = expectation(description: "Generation finished")
    let token = chat.$state.dropFirst().filter { state in
      if case .failed = state { return true }; return state == .idle
    }.prefix(1).sink { _ in expectation.fulfill() }
    return (expectation, token)
  }

  private func attachment() throws -> ScreenAttachment {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3200, pixelsHigh: 1600, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    var attachment = try ScreenAttachment(image: NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: 3200, height: 1600)))
    attachment.ocrText = ocr
    attachment.ocrConfidence = 0.9
    return attachment
  }

  private func makeFixture(cloud: PipelineCloud = PipelineCloud(), withVision: Bool = false) throws -> PipelineFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenPipeline-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let modelURL = directory.appendingPathComponent("text.gguf")
    let projector = directory.appendingPathComponent("mmproj.gguf")
    let header = Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0])
    try header.write(to: modelURL)
    try header.write(to: projector)
    let text = LocalModel(id: "text", displayName: "Text", fileURL: modelURL)
    let visual = LocalModel(id: "visual", displayName: "Vision", fileURL: modelURL,
      visionConfiguration: LocalVisionConfiguration(projectorURL: projector, serverExecutableURL: URL(fileURLWithPath: "/usr/bin/true")))
    let engine = PipelineEngine(model: text, models: withVision ? [text, visual] : [text])
    let vision = PipelineVision()
    let store = ChatSessionStore(applicationSupportDirectory: directory)
    let chat = LocalChatViewModel(engine: engine, visionEngine: vision,
      cloudProviders: CloudProviderRegistry(openAI: cloud, anthropic: cloud, chatGPT: cloud, gemini: cloud), sessionStore: store)
    return PipelineFixture(chat: chat, engine: engine, vision: vision, cloud: cloud, store: store, text: text)
  }
}

@MainActor
private struct PipelineFixture {
  let chat: LocalChatViewModel
  let engine: PipelineEngine
  let vision: PipelineVision
  let cloud: PipelineCloud
  let store: ChatSessionStore
  let text: LocalModel
}

private actor PipelineEngine: LocalModelEngine {
  let model: LocalModel
  let models: [LocalModel]
  var requests: [LocalModelRequest] = []
  var unloads = 0
  init(model: LocalModel, models: [LocalModel]) { self.model = model; self.models = models }
  func installedModel() -> LocalModel? { model }
  func installedModels() -> [LocalModel] { models }
  func install(_ model: LocalModel) throws {}
  func selectModel(id: String) throws {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) throws -> LocalModel { self.model }
  func prepare(_ request: LocalModelRequest) throws -> PreparedConversation {
    requests.append(request)
    return try ChatContextPreparer.prepare(request.messages, budget: ContextBudget(contextWindow: 4096, outputTokens: 512, overheadTokens: 256), countTokens: { $0.reduce(0) { $0 + $1.content.utf8.count } })
  }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.yield("local answer"); $0.finish() }
  }
  func unload() { unloads += 1 }
}

private final class PipelineCloud: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: [ChatRequest] = []
  let error: CloudProviderError?
  let controlled: AsyncThrowingStream<ChatEvent, Error>?
  let started: (@Sendable () -> Void)?
  let controlledStreams: [AsyncThrowingStream<ChatEvent, Error>]
  let onStarted: (@Sendable (Int) -> Void)?
  var requests: [ChatRequest] { lock.withLock { captured } }
  init(error: CloudProviderError? = nil, controlled: AsyncThrowingStream<ChatEvent, Error>? = nil, started: (@Sendable () -> Void)? = nil,
       controlledStreams: [AsyncThrowingStream<ChatEvent, Error>] = [], onStarted: (@Sendable (Int) -> Void)? = nil) {
    self.error = error; self.controlled = controlled; self.started = started
    self.controlledStreams = controlledStreams; self.onStarted = onStarted
  }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    let index = lock.withLock { captured.append(request); return captured.count - 1 }
    started?()
    onStarted?(index)
    if controlledStreams.indices.contains(index) { return controlledStreams[index] }
    if let controlled { return controlled }
    return AsyncThrowingStream {
      if let error { $0.finish(throwing: error) }
      else { $0.yield(.token("cloud answer")); $0.yield(.completed); $0.finish() }
    }
  }
}

private final class PipelineVision: LocalVisionServing, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var imageCount: Int { lock.withLock { count } }
  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) -> AsyncThrowingStream<String, Error> {
    if image != nil { lock.withLock { count += 1 } }
    return AsyncThrowingStream { $0.yield("local vision answer"); $0.finish() }
  }
}

private struct PipelineOCR: ScreenOCRReading {
  let text: String
  func recognize(_ image: CGImage) async throws -> ScreenOCRResult { ScreenOCRResult(text: text, confidence: 0.9) }
}

@MainActor
private struct PipelineCapture: ScreenCapturing {
  func capture() async throws -> NSImage? {
    NSImage(size: NSSize(width: 100, height: 50), flipped: false) { rect in
      NSColor.white.setFill(); rect.fill(); return true
    }
  }
}
