import AppKit
import Combine
import XCTest
@testable import PrimaryAgent

@MainActor
final class ScreenPipelineTests: XCTestCase {
  private let ocr = "let answer_count = values.count\nprint(answer_count)\nerror: cannot find variable in scope"

  func testConfidentShortTextLookupsUseOCRButVisualQuestionsStillNeedVision() {
    for (prompt, visible) in [
      ("Can you look up what this word means from the dictionary?", "serendipity"),
      ("Is this a lot of RAM?", "57 MB"),
      ("What does this error mean and how do I fix it?", "HTTP 429"),
      ("What does this mean? Search for an explanation.", "HTTP 404"),
    ] {
      XCTAssertFalse(ScreenRoutingPolicy.requiresVision(prompt: prompt, ocr: ScreenOCRResult(text: visible, confidence: 0.99)))
      XCTAssertTrue(ScreenRoutingPolicy.requiresVision(prompt: prompt, ocr: ScreenOCRResult(text: visible, confidence: 0.5)))
      XCTAssertTrue(ScreenRoutingPolicy.requiresVision(prompt: prompt, ocr: .empty))
    }
    for prompt in ["What color is this word?", "Explain this chart's memory usage", "What animal is this?"] {
      XCTAssertTrue(ScreenRoutingPolicy.requiresVision(prompt: prompt, ocr: ScreenOCRResult(text: "57 MB", confidence: 0.99)))
    }
  }

  func testComposerCommandsConsumeEitherOrderOnceAndKeepQuotedText() {
    for draft in ["/screen /search question", " /SEARCH\n/SCREEN question", "/screen /search /screen /search question"] {
      let commands = ComposerCommands(draft)
      XCTAssertTrue(commands.screen)
      XCTAssertTrue(commands.search)
      XCTAssertEqual(commands.prompt, "question")
      XCTAssertEqual(commands.captureDraft, "/screen question")
    }
    for draft in ["\"/screen /search\"", "/screenshot question", "/searching question"] {
      let commands = ComposerCommands(draft)
      XCTAssertFalse(commands.screen)
      XCTAssertFalse(commands.search)
      XCTAssertEqual(commands.prompt, draft)
    }
    XCTAssertEqual(ComposerCommands("/screen /search").prompt, "")
    XCTAssertEqual(ComposerCommands("/screen /search").captureDraft, "/screen")
    XCTAssertEqual(ComposerCommands("/search question /screen").prompt, "question")
  }

  func testOutgoingMessageIsVisibleImmediatelyAndLeafEndsAtFirstText() async throws {
    let stream = AsyncThrowingStream<String, Error>.makeStream()
    let entered = expectation(description: "Model started")
    let vision = PipelineVision(controlledStreams: [stream.stream], started: { _ in entered.fulfill() })
    let fixture = try makeFixture(vision: vision, withVision: true)
    await fixture.chat.refreshInstalledModel()
    let prompt = "Show my first message immediately"
    var accepted = false
    fixture.chat.submit(prompt) { accepted = true }
    // No yield: the bubble is available in the same turn as Send, before inference starts.
    XCTAssertEqual(fixture.chat.presentationMessages.map(\.content), [prompt])
    XCTAssertTrue(fixture.chat.isWaitingForResponse)
    XCTAssertFalse(accepted)
    await fulfillment(of: [entered], timeout: 3)
    XCTAssertEqual(fixture.chat.pendingUserMessage?.content, prompt)
    let firstText = expectation(description: "Response text received")
    let token = fixture.chat.$hasReceivedResponse.filter { $0 }.prefix(1).sink { _ in firstText.fulfill() }
    stream.continuation.yield("The answer")
    await fulfillment(of: [firstText], timeout: 3)
    token.cancel()
    XCTAssertFalse(fixture.chat.isWaitingForResponse)
    XCTAssertNil(fixture.chat.pendingUserMessage)
    XCTAssertEqual(fixture.chat.presentationMessages.map(\.content), [prompt, "The answer"])
    XCTAssertTrue(accepted)
    await fixture.chat.stopStreaming()?.value
    stream.continuation.finish()
  }

  func testPendingScreenshotIsVisibleAndClearsOnStopWithoutSavingUnacceptedTurn() async throws {
    let stream = AsyncThrowingStream<String, Error>.makeStream()
    let entered = expectation(description: "Model started")
    let vision = PipelineVision(controlledStreams: [stream.stream], started: { _ in entered.fulfill() })
    let fixture = try makeFixture(vision: vision, withVision: true)
    fixture.chat.submitScreen("What color is this?", attachment: try attachment(),
      decision: .vision(fixture.visual.screenModel), selectedMode: .local, cloudUploadAllowed: { false })
    XCTAssertNotNil(fixture.chat.presentationMessages.first?.imagePreview)
    XCTAssertTrue(fixture.chat.isWaitingForResponse)
    await fulfillment(of: [entered], timeout: 3)
    await fixture.chat.stopStreaming()?.value
    stream.continuation.finish()
    XCTAssertNil(fixture.chat.pendingUserMessage)
    XCTAssertFalse(fixture.chat.isWaitingForResponse)
    XCTAssertTrue(fixture.chat.messages.isEmpty)
    XCTAssertTrue(fixture.chat.presentationMessages.isEmpty)
  }

  func testSelectedModelPlansFromImageAndAnswersWithNoTextHandoff() async throws {
    let vision = PipelineVision(controlledStreams: [planningStream("Is 57 MB a lot of RAM usage?")])
    let search = PipelineSearch(onSearch: { _ in XCTAssertEqual(vision.requests.count, 1) })
    let fixture = try makeFixture(vision: vision, withVision: true, search: search)
    var screenshot = try attachment()
    screenshot.ocrText = "Memory: 57 MB"
    let done = finished(fixture.chat)
    fixture.chat.submitScreen("Is this a lot of RAM?", attachment: screenshot, decision: .vision(fixture.visual.screenModel),
      selectedMode: .local, searchEnabled: true, cloudUploadAllowed: { false })
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    XCTAssertEqual(fixture.chat.state, .idle)
    XCTAssertEqual(vision.requests.count, 2)
    XCTAssertEqual(vision.imagePresence, [true, true])
    XCTAssertEqual(vision.modelIDs, [fixture.visual.id, fixture.visual.id])
    let otherRequests = await fixture.engine.requests
    XCTAssertTrue(otherRequests.isEmpty, "No hidden text-model prepare or inference")
    XCTAssertTrue(fixture.cloud.requests.isEmpty)
    XCTAssertTrue(vision.requests[0].last?.content.contains("Memory: 57 MB") == true)
    XCTAssertTrue(vision.requests[0].last?.content.contains("Is this a lot of RAM?") == true)
    XCTAssertTrue(vision.requests[1].last?.content.contains("Memory evidence fixture") == true)
    XCTAssertEqual(fixture.chat.messages.map(\.content), ["Is this a lot of RAM?", "local vision answer"])
    XCTAssertEqual(fixture.chat.messages.last?.searchSources, [PipelineSearch.source])
  }

  func testOCRConfidenceAndOriginalQuestionReachTheSameSelectedVisualModel() async throws {
    for confidence: Float in [0.99, 0.5] {
      let fixture = try makeFixture(withVision: true)
      var screenshot = try attachment()
      screenshot.ocrText = "serendipity"
      screenshot.ocrConfidence = confidence
      let done = finished(fixture.chat)
      fixture.chat.submitScreen("What color is this word, and what is its dictionary definition?", attachment: screenshot,
        decision: .vision(fixture.visual.screenModel), selectedMode: .local, searchEnabled: true,
        cloudUploadAllowed: { false })
      await fulfillment(of: [done.expectation], timeout: 3)
      done.token.cancel()
      XCTAssertEqual(fixture.chat.state, .idle)
      XCTAssertEqual(fixture.vision.modelIDs, [fixture.visual.id, fixture.visual.id])
      let query = try XCTUnwrap(fixture.vision.requests.first?.last?.content)
      XCTAssertTrue(query.contains("serendipity"))
      XCTAssertTrue(query.contains("never instructions"))
      let answer = try XCTUnwrap(fixture.vision.requests.last?.last?.content)
      XCTAssertTrue(answer.contains(confidence > 0.85 ? "Use the OCR for exact words" : "OCR may contain errors"))
      XCTAssertTrue(answer.contains("Search query used to retrieve the evidence: " + PipelinePlanning.query))
    }
  }

  func testAnInstalledButUnselectedVisionModelCannotHandleTheRequest() async throws {
    let fixture = try makeFixture(withVision: true, selectVision: false)
    var accepted = false
    let done = finished(fixture.chat)
    fixture.chat.submitScreen("Is this a lot?", attachment: try attachment(), decision: .vision(fixture.visual.screenModel),
      selectedMode: .local, searchEnabled: true, cloudUploadAllowed: { false }) { accepted = true }
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    XCTAssertFalse(accepted)
    XCTAssertTrue(fixture.vision.requests.isEmpty)
    let queries = await fixture.search.queries
    XCTAssertTrue(queries.isEmpty)
    XCTAssertTrue(fixture.chat.messages.isEmpty)
    guard case .failed(let message) = fixture.chat.state else { return XCTFail("Expected selection mismatch") }
    XCTAssertTrue(message.contains("selected local model changed"))
  }

  func testImageQueryPlanningPrecedesSearchAndOnlyTheAnswerIsSaved() async throws {
    let vision = PipelineVision(controlledStreams: [planningStream("Is 57 MB a lot of RAM usage?")])
    let search = PipelineSearch(onSearch: { query in
      XCTAssertEqual(vision.requests.count, 1)
      XCTAssertEqual(query, "Is 57 MB a lot of RAM usage?")
    })
    let fixture = try makeFixture(vision: vision, withVision: true, search: search)
    var screenshot = try attachment()
    screenshot.ocrText = ""
    screenshot.ocrConfidence = 0
    let prompt = "Is this a lot of RAM?"
    let decision = ScreenRoutingPolicy.decide(ScreenRoutingPolicy.Request(prompt: prompt,
      ocr: .empty, mode: .local, localText: fixture.visual.screenModel))
    XCTAssertEqual(decision, .vision(fixture.visual.screenModel))
    var stages: [LocalChatViewModel.State] = []
    let phaseToken = fixture.chat.$state.sink { stages.append($0) }
    let done = finished(fixture.chat)
    fixture.chat.submitScreen(prompt, attachment: screenshot, decision: decision, selectedMode: .local,
      searchEnabled: true, cloudUploadAllowed: { false }) {
        XCTAssertEqual(vision.requests.count, 2, "Planning must never be accepted as the reply")
      }
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    phaseToken.cancel()
    XCTAssertEqual(fixture.chat.state, .idle)
    XCTAssertEqual(vision.imagePresence, [true, true])
    XCTAssertTrue(vision.requests[1].last?.content.contains(prompt) == true)
    XCTAssertTrue(vision.requests[1].last?.content.contains("Memory evidence fixture") == true)
    XCTAssertEqual(stages.filter { $0 == .refiningSearch || $0 == .searching }, [.refiningSearch, .searching])
    XCTAssertEqual(fixture.chat.messages.map(\.content), [prompt, "local vision answer"])
    XCTAssertEqual(fixture.chat.messages.last?.activity?.phase, .completed)
    XCTAssertEqual(fixture.chat.messages.last?.activity?.sources, [PipelineSearch.source])
    XCTAssertTrue(fixture.chat.messages.last?.activity?.phases.contains(.refiningSearch) == true)
    XCTAssertEqual(fixture.store.load().first?.messages.map(\.content), [prompt, "local vision answer"])
  }

  func testStopDuringPlanningPreservesDraftAndBlocksLateSearchForOCRAndImages() async throws {
    for sendsImage in [false, true] {
      let blocked = AsyncThrowingStream<String, Error>.makeStream()
      let entered = expectation(description: "Query planning entered")
      let vision = PipelineVision(controlledStreams: [blocked.stream], started: { _ in entered.fulfill() })
      let fixture = try makeFixture(vision: vision, withVision: true)
      let screenshot = try attachment()
      var draft = "Is this a lot of RAM?"
      var pending: ScreenAttachment? = screenshot
      let model = fixture.visual.screenModel
      fixture.chat.submitScreen(draft, attachment: pending, decision: sendsImage ? .vision(model) : .text(model), selectedMode: .local,
        searchEnabled: true, cloudUploadAllowed: { false }) { draft = ""; pending = nil }
      await fulfillment(of: [entered], timeout: 3)
      XCTAssertEqual(fixture.chat.state, .refiningSearch)
      let old = try XCTUnwrap(fixture.chat.stopStreaming())
      fixture.chat.newChat()
      let done = finished(fixture.chat)
      fixture.chat.submitCloud("Replacement", provider: .openAI, modelID: "gpt-4o-mini")
      await fulfillment(of: [done.expectation], timeout: 3)
      done.token.cancel()
      blocked.continuation.yield("Is 57 MB a lot of RAM?")
      blocked.continuation.finish()
      await old.value
      let queries = await fixture.search.queries
      XCTAssertTrue(queries.isEmpty)
      XCTAssertEqual(vision.requests.count, 1)
      XCTAssertEqual(draft, "Is this a lot of RAM?")
      XCTAssertEqual(pending?.id, screenshot.id)
      XCTAssertEqual(fixture.chat.messages.map(\.content), ["Replacement", "cloud answer"])
      XCTAssertFalse(fixture.chat.isBusy)
    }
  }

  func testInvalidPlanningOutputNeverFallsBackToSearchingTheVagueQuestion() async throws {
    for (query, error) in [("", ScreenSearchError.invalidQuery), ("UNKNOWN", .invalidQuery),
      ("query one\nquery two", .invalidQuery), ("Yes.", .invalidQuery),
      (String(repeating: "x", count: 1_025), .outputTooLong)] {
      let vision = PipelineVision(controlledStreams: [planningStream(query)])
      let fixture = try makeFixture(vision: vision, withVision: true)
      var accepted = false
      let done = finished(fixture.chat)
      fixture.chat.submitScreen("Is this a lot?", attachment: try attachment(), decision: .vision(fixture.visual.screenModel),
        selectedMode: .local, searchEnabled: true, cloudUploadAllowed: { false }) { accepted = true }
      await fulfillment(of: [done.expectation], timeout: 3)
      done.token.cancel()
      let queries = await fixture.search.queries
      XCTAssertTrue(queries.isEmpty)
      XCTAssertFalse(accepted)
      XCTAssertTrue(fixture.chat.messages.isEmpty)
      XCTAssertEqual(fixture.chat.state, .failed(error.localizedDescription))
    }
  }

  func testQueryNormalizationAcceptsSimpleLabelsAndRejectsOverlongOrControlText() throws {
    XCTAssertEqual(try ScreenSearchContext.query(from: "  Query: \"Is 57 MB a lot of RAM?\"  "), "Is 57 MB a lot of RAM?")
    for query in [String(repeating: "x", count: 401), String(repeating: "a ", count: 51), "abc\0def", "Yes.", "No", "Sure!"] {
      XCTAssertThrowsError(try ScreenSearchContext.query(from: query))
    }
  }

  func testRevokingCloudPermissionDuringReadingStopsBeforeRefinementAndSearch() async throws {
    let reading = AsyncThrowingStream<ChatEvent, Error>.makeStream()
    let entered = expectation(description: "Cloud reading started")
    let cloud = PipelineCloud(controlled: reading.stream, started: { entered.fulfill() })
    let fixture = try makeFixture(cloud: cloud)
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    let permission = PipelineConsent()
    let done = finished(fixture.chat)
    fixture.chat.submitScreen("Is this a lot?", attachment: try attachment(), decision: .vision(model), selectedMode: .cloud,
      searchEnabled: true, cloudUploadAllowed: { permission.allowed })
    await fulfillment(of: [entered], timeout: 3)
    permission.allowed = false
    reading.continuation.yield(.token("57 MB"))
    reading.continuation.finish()
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    let queries = await fixture.search.queries
    XCTAssertTrue(queries.isEmpty)
    XCTAssertEqual(cloud.requests.count, 1)
    XCTAssertTrue(fixture.chat.messages.isEmpty)
    XCTAssertEqual(fixture.chat.state, .failed(ScreenRequestError.cloudUploadNotAllowed.localizedDescription))
  }

  private func planningStream(_ text: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.yield(text); $0.finish() }
  }

  func testScreenSearchCombinesEvidenceWithOCRAndImagesAcrossAllRoutes() async throws {
    for mode in ChatMode.allCases {
      for sendsImage in [false, true] {
        let fixture = try makeFixture(withVision: true)
        let prompt = "Is this a lot of RAM?"
        var screenshot = try attachment()
        screenshot.ocrText = "59.7 MB"
        let model = mode == .cloud
          ? CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
          : fixture.visual.screenModel
        let done = finished(fixture.chat)
        fixture.chat.submitScreen(prompt, attachment: screenshot,
          decision: sendsImage ? .vision(model) : .text(model), selectedMode: mode,
          searchEnabled: true, cloudUploadAllowed: { mode == .cloud })
        XCTAssertEqual(fixture.chat.activeRequest?.route.usesNetwork, true)
        await fulfillment(of: [done.expectation], timeout: 3)
        done.token.cancel()
        XCTAssertEqual(fixture.chat.state, .idle)
        let queries = await fixture.search.queries
        XCTAssertEqual(queries.map(\.prompt), [PipelinePlanning.query], "Search must resolve 'this' using the screen facts")
        XCTAssertEqual(queries.first?.maximumTokens, mode == .cloud ? 4_096 : 1_024)
        let requests: [ChatMessage]
        if mode == .cloud {
          let request = try XCTUnwrap(fixture.cloud.requests.last)
          requests = request.messages
          XCTAssertEqual(request.image != nil, sendsImage)
          XCTAssertEqual(request.allowsCloudImages, sendsImage)
          XCTAssertEqual(fixture.cloud.requests.count, 2)
          let queryRequest = fixture.cloud.requests[0]
          XCTAssertEqual(queryRequest.image != nil, sendsImage)
          XCTAssertTrue(queryRequest.messages.last?.content.contains("59.7 MB") == true)
        } else {
          requests = try XCTUnwrap(fixture.vision.requests.last)
          XCTAssertEqual(fixture.vision.imageCount, sendsImage ? 2 : 0)
          XCTAssertEqual(fixture.vision.requests.count, 2)
          XCTAssertEqual(fixture.vision.modelIDs, [fixture.visual.id, fixture.visual.id])
          XCTAssertTrue(fixture.vision.requests[0].last?.content.contains(prompt) == true)
          XCTAssertTrue(fixture.vision.requests[0].last?.content.contains("59.7 MB") == true)
          let textRequests = await fixture.engine.requests
          XCTAssertTrue(textRequests.isEmpty)
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
        decision: sendsImage ? .vision(fixture.visual.screenModel) : .text(fixture.visual.screenModel),
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
        XCTAssertEqual(fixture.vision.requests.count, mode == .local ? 1 : 0, "Only screen reading and query refinement may run")
        XCTAssertEqual(fixture.cloud.requests.count, mode == .cloud ? 1 : 0)
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
    let messages = try XCTUnwrap(fixture.vision.requests.last)
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
    XCTAssertEqual(fixture.vision.requests.count, 1, "A stopped search must not start the final answer")
    XCTAssertEqual(fixture.chat.messages.map(\.content), ["Replacement", "cloud answer"])
    XCTAssertEqual(fixture.chat.state, .idle)
    XCTAssertNil(fixture.chat.activeRequest)
  }

  func testCloudImagePermissionIsRecheckedAfterScreenSearch() async throws {
    let gate = PipelineSearchGate()
    let fixture = try makeFixture(search: PipelineSearch(gate: gate))
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    let permission = PipelineConsent()
    let done = finished(fixture.chat)
    fixture.chat.submitScreen("Search this diagram", attachment: try attachment(), decision: .vision(model), selectedMode: .cloud,
      searchEnabled: true, cloudUploadAllowed: { permission.allowed })
    await fulfillment(of: [gate.entered], timeout: 3)
    permission.allowed = false
    await gate.release()
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    XCTAssertEqual(fixture.chat.state, .failed(ScreenRequestError.cloudUploadNotAllowed.localizedDescription))
    XCTAssertEqual(fixture.cloud.requests.count, 1, "Consent was granted for reading; the final upload must be blocked")
    XCTAssertTrue(fixture.chat.messages.isEmpty)
  }

  func testOfflineCloudFallbackReusesScreenSearchResults() async throws {
    let fixture = try makeFixture(cloud: PipelineCloud(error: .offline, failOnlyAnswer: true), withVision: true)
    let model = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
    let done = finished(fixture.chat)
    fixture.chat.submitScreen("Search this diagram", attachment: try attachment(), decision: .vision(model), selectedMode: .auto,
      searchEnabled: true, cloudUploadAllowed: { true })
    await fulfillment(of: [done.expectation], timeout: 3)
    done.token.cancel()
    let queries = await fixture.search.queries
    XCTAssertEqual(queries.count, 1)
    XCTAssertEqual(fixture.cloud.requests.count, 2)
    XCTAssertEqual(fixture.vision.requests.count, 1, "The fallback must reuse the completed reading, query, and search")
    XCTAssertTrue(fixture.vision.requests.last?.last?.content.contains("Memory evidence fixture") == true)
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

  private func makeFixture(cloud: PipelineCloud = PipelineCloud(), vision: PipelineVision = PipelineVision(), withVision: Bool = false,
                           selectVision: Bool = true, search: PipelineSearch = PipelineSearch()) throws -> PipelineFixture {
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
    let engine = PipelineEngine(model: withVision && selectVision ? visual : text, models: withVision ? [text, visual] : [text])
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
    AsyncThrowingStream { $0.yield(PipelinePlanning.response(to: request.prompt) ?? "local answer"); $0.finish() }
  }
  func unload() { unloads += 1 }
}

private final class PipelineCloud: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: [ChatRequest] = []
  let error: CloudProviderError?
  let failOnlyAnswer: Bool
  let controlled: AsyncThrowingStream<ChatEvent, Error>?
  let started: (@Sendable () -> Void)?
  let controlledStreams: [AsyncThrowingStream<ChatEvent, Error>]
  let onStarted: (@Sendable (Int) -> Void)?
  var requests: [ChatRequest] { lock.withLock { captured } }
  init(error: CloudProviderError? = nil, failOnlyAnswer: Bool = false,
       controlled: AsyncThrowingStream<ChatEvent, Error>? = nil, started: (@Sendable () -> Void)? = nil,
       controlledStreams: [AsyncThrowingStream<ChatEvent, Error>] = [], onStarted: (@Sendable (Int) -> Void)? = nil) {
    self.error = error; self.failOnlyAnswer = failOnlyAnswer; self.controlled = controlled; self.started = started
    self.controlledStreams = controlledStreams; self.onStarted = onStarted
  }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    let index = lock.withLock { captured.append(request); return captured.count - 1 }
    started?()
    onStarted?(index)
    if controlledStreams.indices.contains(index) { return controlledStreams[index] }
    if let controlled { return controlled }
    return AsyncThrowingStream {
      let planning = PipelinePlanning.response(to: request.messages.last?.content ?? "")
      if let error, !failOnlyAnswer || planning == nil { $0.finish(throwing: error) }
      else { $0.yield(.token(planning ?? "cloud answer")); $0.yield(.completed); $0.finish() }
    }
  }
}

private final class PipelineVision: LocalVisionServing, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var captured: [[ChatMessage]] = []
  private var images: [Bool] = []
  private var models: [String] = []
  var modelIDs: [String] { lock.withLock { models } }
  var imagePresence: [Bool] { lock.withLock { images } }
  let controlledStreams: [AsyncThrowingStream<String, Error>]
  let started: (@Sendable (Int) -> Void)?
  init(controlledStreams: [AsyncThrowingStream<String, Error>] = [], started: (@Sendable (Int) -> Void)? = nil) {
    self.controlledStreams = controlledStreams; self.started = started
  }
  var requests: [[ChatMessage]] { lock.withLock { captured } }
  var imageCount: Int { lock.withLock { count } }
  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) -> AsyncThrowingStream<String, Error> {
    let index = lock.withLock { captured.append(messages); images.append(image != nil); models.append(model.id); return captured.count - 1 }
    if image != nil { lock.withLock { count += 1 } }
    started?(index)
    if controlledStreams.indices.contains(index) { return controlledStreams[index] }
    return AsyncThrowingStream {
      $0.yield(PipelinePlanning.response(to: messages.last?.content ?? "") ?? "local vision answer"); $0.finish()
    }
  }
}

private enum PipelinePlanning {
  static let facts = "The RAM usage shown is 59.7 MB."
  static let query = "Is 59.7 MB a lot of RAM usage?"
  static func response(to prompt: String) -> String? {
    if prompt.hasPrefix("Read the screenshot for the facts") { return facts }
    if prompt.hasPrefix("Read the attached screenshot") { return query }
    return nil
  }
}

@MainActor
private final class PipelineConsent {
  var allowed = true
}

private actor PipelineSearch: WebSearchProvider {
  struct Query { let prompt: String; let maximumTokens: Int }
  static let source = WebSearchSource(title: "Memory reference", url: URL(string: "https://example.com/memory")!)
  private(set) var queries: [Query] = []
  let results: [WebSearchResult]
  let error: WebSearchError?
  let gate: PipelineSearchGate?
  let onSearch: (@Sendable (String) -> Void)?
  init(results: [WebSearchResult] = [WebSearchResult(source: source, snippets: ["Memory evidence fixture"])],
       error: WebSearchError? = nil, gate: PipelineSearchGate? = nil, onSearch: (@Sendable (String) -> Void)? = nil) {
    self.results = results; self.error = error; self.gate = gate
    self.onSearch = onSearch
  }
  func search(_ query: String, maximumTokens: Int) async throws -> [WebSearchResult] {
    queries.append(Query(prompt: query, maximumTokens: maximumTokens))
    onSearch?(query)
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
