import AppKit
import Combine
import XCTest
@testable import PrimaryAgent

@MainActor
final class ScreenPipelineTests: XCTestCase {
  private let ocr = "let answer_count = values.count\nprint(answer_count)\nerror: cannot find variable in scope"

  func testScreenSearchCombinesEvidenceWithOCRAndImagesAcrossAllRoutes() async throws {
    for mode in ChatMode.allCases {
      for sendsImage in [false, true] {
        let fixture = try makeFixture(withVision: true)
        let prompt = "How much RAM am I using and can you search if that is a lot?"
        var screenshot = try attachment()
        screenshot.ocrText = "59.7 MB"
        let model = mode == .cloud
          ? CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
          : (sendsImage ? fixture.visual : fixture.text).screenModel
        let done = finished(fixture.chat)
        fixture.chat.submitScreen(prompt, attachment: screenshot,
          decision: sendsImage ? .vision(model) : .text(model), selectedMode: mode,
          searchEnabled: true, cloudUploadAllowed: { mode == .cloud })
        XCTAssertEqual(fixture.chat.activeRequest?.route.usesNetwork, true)
        await fulfillment(of: [done.expectation], timeout: 3)
        done.token.cancel()
        XCTAssertEqual(fixture.chat.state, .idle)
        let queries = await fixture.search.queries
        XCTAssertEqual(queries.map(\.prompt), [prompt], "OCR must stay out of the search query")
        XCTAssertEqual(queries.first?.maximumTokens, mode == .cloud ? 4_096 : 1_024)
        let requests: [ChatMessage]
        if mode == .cloud {
          let request = try XCTUnwrap(fixture.cloud.requests.first)
          requests = request.messages
          XCTAssertEqual(request.image != nil, sendsImage)
          XCTAssertEqual(request.allowsCloudImages, sendsImage)
        } else if sendsImage {
          requests = try XCTUnwrap(fixture.vision.requests.first)
          XCTAssertEqual(fixture.vision.imageCount, 1)
          XCTAssertTrue(fixture.cloud.requests.isEmpty)
        } else {
          let request = await fixture.engine.lastRequest()
          requests = try XCTUnwrap(request).messages
          XCTAssertEqual(fixture.vision.imageCount, 0)
          XCTAssertTrue(fixture.cloud.requests.isEmpty)
        }
        let context = try XCTUnwrap(requests.last?.content)
        XCTAssertTrue(context.contains(prompt))
        XCTAssertTrue(context.contains("59.7 MB"))
        XCTAssertTrue(context.contains("Memory evidence fixture"))
        XCTAssertTrue(context.contains("untrusted web data"))
        XCTAssertTrue(context.contains("untrusted source content"))
        let saved = try XCTUnwrap(fixture.store.load().first).messages
        XCTAssertEqual(saved.first?.content, prompt)
        XCTAssertNil(saved.first?.imagePreview)
        XCTAssertNotNil(fixture.chat.messages.first?.imagePreview)
        XCTAssertEqual(saved.last?.searchSources, [PipelineSearch.source])
        XCTAssertFalse(saved.contains { $0.content.contains("Memory evidence fixture") || $0.content.contains("59.7 MB") })
      }
    }
  }

  func testSearchStillRunsWhenSelectedVisionModelReceivesTextWithoutAttachment() async throws {
    let fixture = try makeFixture(withVision: true, selectVision: true)
    await fixture.chat.refreshInstalledModel()
    let done = finished(fixture.chat)
    fixture.chat.submit("Search typical memory usage", searchEnabled: true)
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    let queries = await fixture.search.queries
    XCTAssertEqual(queries.map(\.prompt), ["Search typical memory usage"])
    XCTAssertEqual(fixture.vision.imageCount, 0)
    XCTAssertTrue(fixture.vision.requests.first?.last?.content.contains("Memory evidence fixture") == true)
    XCTAssertEqual(fixture.chat.messages.last?.searchSources, [PipelineSearch.source])
  }

  func testScreenWithoutSearchNeverContactsBrave() async throws {
    for sendsImage in [false, true] {
      let fixture = try makeFixture(withVision: true)
      let done = finished(fixture.chat)
      fixture.chat.submitScreen("Read this", attachment: try attachment(),
        decision: sendsImage ? .vision(fixture.visual.screenModel) : .text(fixture.text.screenModel),
        selectedMode: .local, cloudUploadAllowed: { false })
      await fulfillment(of: [done.expectation], timeout: 3)
      done.token.cancel()
      let queries = await fixture.search.queries
      XCTAssertTrue(queries.isEmpty)
      XCTAssertNil(fixture.chat.messages.last?.searchSources)
    }
  }

  func testScreenSearchFailuresKeepDraftAndAttachmentWithoutStartingGeneration() async throws {
    for mode in [ChatMode.local, .cloud] {
      for error in [WebSearchError.missingAPIKey, .noResults] {
        let fixture = try makeFixture(withVision: true, search: PipelineSearch(error: error))
        let screenshot = try attachment()
        var draft = "Read and search this"
        var pending: ScreenAttachment? = screenshot
        let model = mode == .local ? fixture.visual.screenModel
          : CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
        let done = finished(fixture.chat)
        fixture.chat.submitScreen(draft, attachment: pending, decision: .vision(model), selectedMode: mode,
          searchEnabled: true, cloudUploadAllowed: { true }) { draft = ""; pending = nil }
        await fulfillment(of: [done.expectation], timeout: 3)
        done.token.cancel()
        XCTAssertEqual(fixture.chat.state, .failed(error.localizedDescription))
        XCTAssertEqual(draft, "Read and search this")
        XCTAssertEqual(pending?.id, screenshot.id)
        XCTAssertTrue(fixture.chat.messages.isEmpty)
        XCTAssertTrue(fixture.vision.requests.isEmpty)
        XCTAssertTrue(fixture.cloud.requests.isEmpty)
      }
    }
  }

  func testScreenSearchFitsEvidenceAroundReservedImageBudgetAndPreservesQuestion() async throws {
    let search = PipelineSearch(results: [WebSearchResult(source: PipelineSearch.source,
      snippets: [String(repeating: "Memory evidence fixture ", count: 500)])])
    let fixture = try makeFixture(withVision: true, search: search)
    let prompt = String(repeating: "Full question ", count: 140)
    let screenshot = try attachment()
    let done = finished(fixture.chat)
    fixture.chat.submitScreen(prompt, attachment: screenshot, decision: .vision(fixture.visual.screenModel),
      selectedMode: .local, searchEnabled: true, cloudUploadAllowed: { false })
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    XCTAssertEqual(fixture.chat.state, .idle)
    let messages = try XCTUnwrap(fixture.vision.requests.first)
    XCTAssertTrue(messages.last?.content.contains(prompt.trimmingCharacters(in: .whitespacesAndNewlines)) == true)
    XCTAssertTrue(messages.last?.content.contains(ocr) == true)
    let image = try ScreenImagePreprocessor.prepare(XCTUnwrap(screenshot.originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    let prepared = try LlamaServerVisionEngine.prepare(messages: messages, image: image, model: fixture.visual)
    XCTAssertLessThanOrEqual(prepared.inputTokenCount, prepared.budget.availableInputTokens)
    XCTAssertEqual(fixture.chat.messages.last?.searchSources, [PipelineSearch.source])
  }

  func testOversizedScreenQuestionFailsBeforeSearching() async throws {
    let fixture = try makeFixture(withVision: true)
    let done = finished(fixture.chat)
    fixture.chat.submitScreen(String(repeating: "x", count: 10_000), attachment: try attachment(),
      decision: .vision(fixture.visual.screenModel), selectedMode: .local,
      searchEnabled: true, cloudUploadAllowed: { false })
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    guard case .failed = fixture.chat.state else { return XCTFail("Expected context failure") }
    let queries = await fixture.search.queries
    XCTAssertTrue(queries.isEmpty)
    XCTAssertTrue(fixture.vision.requests.isEmpty)
    XCTAssertTrue(fixture.chat.messages.isEmpty)
  }

  func testStopDuringScreenSearchCancelsRetrievalAndIgnoresLateResultsAfterReplacement() async throws {
    let gate = PipelineSearchGate()
    let fixture = try makeFixture(withVision: true, search: PipelineSearch(gate: gate))
    var accepted = false
    fixture.chat.submitScreen("Read and search", attachment: try attachment(), decision: .vision(fixture.visual.screenModel),
      selectedMode: .local, searchEnabled: true, cloudUploadAllowed: { false }) { accepted = true }
    await fulfillment(of: [gate.entered], timeout: 3)
    XCTAssertEqual(fixture.chat.state, .searching)
    let task = try XCTUnwrap(fixture.chat.stopStreaming())
    await fulfillment(of: [gate.cancelled], timeout: 3)
    fixture.chat.newChat()
    let done = finished(fixture.chat)
    fixture.chat.submitCloud("Replacement", provider: .openAI, modelID: "gpt-4o-mini")
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    await gate.release()
    await task.value
    XCTAssertFalse(accepted)
    XCTAssertTrue(fixture.vision.requests.isEmpty)
    XCTAssertEqual(fixture.chat.messages.map(\.content), ["Replacement", "cloud answer"])
    XCTAssertEqual(fixture.chat.state, .idle)
    XCTAssertNil(fixture.chat.activeRequest)
  }

  func testCloudImagePermissionIsRecheckedAfterScreenSearch() async throws {
    let gate = PipelineSearchGate()
    let fixture = try makeFixture(search: PipelineSearch(gate: gate))
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    var allowed = true
    let done = finished(fixture.chat)
    fixture.chat.submitScreen("Search this diagram", attachment: try attachment(), decision: .vision(model), selectedMode: .cloud,
      searchEnabled: true, cloudUploadAllowed: { allowed })
    await fulfillment(of: [gate.entered], timeout: 3)
    allowed = false
    await gate.release()
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    XCTAssertEqual(fixture.chat.state, .failed(ScreenRequestError.cloudUploadNotAllowed.localizedDescription))
    XCTAssertTrue(fixture.cloud.requests.isEmpty)
    XCTAssertTrue(fixture.chat.messages.isEmpty)
  }

  func testOfflineCloudFallbackReusesScreenSearchResults() async throws {
    let fixture = try makeFixture(cloud: PipelineCloud(error: .offline), withVision: true)
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    let done = finished(fixture.chat)
    fixture.chat.submitScreen("Search this diagram", attachment: try attachment(), decision: .vision(model), selectedMode: .auto,
      searchEnabled: true, cloudUploadAllowed: { true })
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    let queries = await fixture.search.queries
    XCTAssertEqual(queries.count, 1)
    XCTAssertEqual(fixture.cloud.requests.count, 1)
    XCTAssertTrue(fixture.vision.requests.first?.last?.content.contains("Memory evidence fixture") == true)
    XCTAssertEqual(fixture.chat.messages.filter { $0.role == .user }.count, 1)
    XCTAssertEqual(fixture.chat.messages.last?.searchSources, [PipelineSearch.source])
    XCTAssertEqual(fixture.chat.screenRouteDecision?.model?.isLocal, true)
  }

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

  private func makeFixture(cloud: PipelineCloud = PipelineCloud(), withVision: Bool = false,
                           selectVision: Bool = false, search: PipelineSearch = PipelineSearch()) throws -> PipelineFixture {
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
    let engine = PipelineEngine(model: selectVision ? visual : text, models: withVision ? [text, visual] : [text])
    let vision = PipelineVision()
    let store = ChatSessionStore(applicationSupportDirectory: directory)
    let chat = LocalChatViewModel(engine: engine, visionEngine: vision,
      cloudProviders: CloudProviderRegistry(openAI: cloud, anthropic: cloud, chatGPT: cloud, gemini: cloud),
      webSearch: search, sessionStore: store)
    return PipelineFixture(chat: chat, engine: engine, vision: vision, cloud: cloud, search: search,
                           store: store, text: text, visual: visual)
  }
}

@MainActor
private struct PipelineFixture {
  let chat: LocalChatViewModel
  let engine: PipelineEngine
  let vision: PipelineVision
  let cloud: PipelineCloud
  let search: PipelineSearch
  let store: ChatSessionStore
  let text: LocalModel
  let visual: LocalModel
}

private actor PipelineEngine: LocalModelEngine {
  let model: LocalModel
  let models: [LocalModel]
  var requests: [LocalModelRequest] = []
  var unloads = 0
  func lastRequest() -> LocalModelRequest? { requests.last }
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
  private var captured: [[ChatMessage]] = []
  var requests: [[ChatMessage]] { lock.withLock { captured } }
  var imageCount: Int { lock.withLock { count } }
  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) -> AsyncThrowingStream<String, Error> {
    lock.withLock { captured.append(messages) }
    if image != nil { lock.withLock { count += 1 } }
    return AsyncThrowingStream { $0.yield("local vision answer"); $0.finish() }
  }
}

private actor PipelineSearch: WebSearchProvider {
  struct Query { let prompt: String; let maximumTokens: Int }
  static let source = WebSearchSource(title: "Memory reference", url: URL(string: "https://example.com/memory")!)
  private(set) var queries: [Query] = []
  let results: [WebSearchResult]
  let error: WebSearchError?
  let gate: PipelineSearchGate?
  init(results: [WebSearchResult] = [WebSearchResult(source: source, snippets: ["Memory evidence fixture"])],
       error: WebSearchError? = nil, gate: PipelineSearchGate? = nil) {
    self.results = results; self.error = error; self.gate = gate
  }
  func search(_ query: String, maximumTokens: Int) async throws -> [WebSearchResult] {
    queries.append(Query(prompt: query, maximumTokens: maximumTokens))
    if let gate {
      await withTaskCancellationHandler {
        await gate.wait()
      } onCancel: { gate.cancelled.fulfill() }
    }
    if let error { throw error }
    return results
  }
}

private actor PipelineSearchGate {
  nonisolated let entered = XCTestExpectation(description: "Screen search started")
  nonisolated let cancelled = XCTestExpectation(description: "Screen search cancelled")
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    await withCheckedContinuation { continuation = $0; entered.fulfill() }
  }
  func release() { continuation?.resume(); continuation = nil }
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
