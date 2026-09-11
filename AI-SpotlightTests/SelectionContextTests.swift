import AppKit
import SwiftUI
import XCTest
@testable import Enigma

@MainActor
final class SelectionContextTests: XCTestCase {
  private var revisionOutput: String {
    "Sure—I’ll make it more professional.\n<enigma-revision>{\"operation\":\"replace_selection\",\"text\":\"Hello team, please send the report today.\"}</enigma-revision>"
  }

  private func revisionSettings(automatic: Bool = false) -> SelectionEditingSettings {
    let settings = SelectionEditingSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    settings.automaticallyReplace = automatic
    return settings
  }

  private func completeRevisionRequest(_ chat: LocalChatViewModel, prompt: String = "Rewrite this professionally", cloud: Bool = false, search: Bool = false) async {
    let done = expectation(description: "revision generation finished")
    let observation = chat.$activeRequest.dropFirst().sink { if $0 == nil { done.fulfill() } }
    if cloud { chat.submitCloud(prompt, provider: .chatGPT, modelID: "fixture", searchEnabled: search) } else { chat.submit(prompt, searchEnabled: search) }
    await fulfillment(of: [done], timeout: 3)
    observation.cancel()
  }

  func testInstalledGemmaAutoProducesRevisionCard() async throws {
    guard ProcessInfo.processInfo.environment["ENIGMA_SELECTION_MODEL_SMOKE"] == "1" else {
      throw XCTSkip("Opt in to exercise installed Gemma with a synthetic selection.")
    }
    let engine = LlamaCPPModelEngine()
    let model = await engine.installedModel()
    XCTAssertTrue(model?.id.contains("12b") == true)
    let vision = LlamaServerVisionEngine()
    let chat = LocalChatViewModel(engine: engine, selectionEditingSettings: revisionSettings(),
      replaceSelection: { _, _ in XCTFail("Live smoke must not paste"); return false },
      visionEngine: vision,
      sessionStore: ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    await chat.refreshInstalledModel()
    chat.startTemporaryChat(context: ConversationContext(sourceName: "Test editor", text: "hey team, send me that report today cuz i need it for the meeting. thanks"))
    let done = expectation(description: "real Gemma revision")
    let observation = chat.$activeRequest.dropFirst().sink { if $0 == nil { done.fulfill() } }
    chat.submitAuto("make the text sound more professional", cloud: nil)
    await fulfillment(of: [done], timeout: 180)
    observation.cancel()
    let revision = chat.selectionRevisions.values.first
    XCTAssertNotNil(revision, "Missing card; response: \(chat.messages.last?.content ?? "none"); notice: \(chat.contextNotice ?? "none")")
    XCTAssertFalse(revision?.text.isEmpty ?? true)
    // Exercise real model recovery too, even when its first response follows the format.
    var recovery = ChatMessage(role: .user, content: SelectionRevisionResponse.recoveryInstructions)
    recovery.contexts = chat.attachedContexts
    let history = [ChatMessage(role: .user, content: "make the text sound more professional"),
      ChatMessage(role: .assistant, content: "Here are three options: formal, friendly, or concise."), recovery]
    let installed = try XCTUnwrap(model)
    let prepared = try await vision.prepare(messages: history, image: nil, model: installed)
    let output = try await ScreenSearchContext.collect(vision.stream(messages: prepared.messages, image: nil, model: installed, temperature: 0), maximumBytes: 300_000)
    if case .revision(let recovered) = SelectionRevisionResponse.recover(output) {
      XCTAssertFalse(recovered.text.isEmpty)
    } else { XCTFail("Gemma recovery failed: \(output)") }
    _ = chat.stopStreaming()
    await vision.unload()
    await engine.unload()
  }

  func testOptionsResponseRecoversOneEditableRevisionOnLocalAndCloud() async throws {
    for cloud in [false, true] {
      let recovered = "{\"operation\":\"replace_selection\",\"text\":\"Please send the report at your earliest convenience.\"}"
      let options = "Here are several options:\n1. Formal wording\n2. Friendly wording"
      let engine = SelectionTestEngine(output: options, recovery: recovered)
      let provider = SelectionTestCloud(output: options, recovery: recovered)
      var pastes: [String] = []
      let chat = LocalChatViewModel(engine: engine, selectionEditingSettings: revisionSettings(),
        replaceSelection: { text, _ in pastes.append(text); return true },
        cloudProviders: CloudProviderRegistry(openAI: provider, anthropic: provider, chatGPT: provider, gemini: provider),
        sessionStore: ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
      chat.startTemporaryChat(context: ConversationContext(sourceName: "Google Chrome", text: "send report now"))
      await completeRevisionRequest(chat, prompt: "make the text sound more professional", cloud: cloud)
      let message = try XCTUnwrap(chat.messages.last)
      let revision = try XCTUnwrap(chat.selectionRevisions[message.id])
      XCTAssertEqual(revision.text, "Please send the report at your earliest convenience.")
      XCTAssertFalse(chat.selectionDisplayMessage(message).content.contains("options"))
      XCTAssertTrue(pastes.isEmpty)
      await chat.applySelectionRevision(messageID: message.id)
      XCTAssertEqual(pastes, [revision.text])
      let request = cloud ? provider.requests.last?.messages.last : engine.lastRequest?.messages.last
      XCTAssertTrue(request?.content.contains("send report now") == true)
      XCTAssertFalse(request?.content.contains(SelectionRevisionResponse.instructions) == true)
    }
  }

  func testFailedRecoveryShowsNoticeWithoutPastingOrRecursing() async {
    let provider = SelectionTestCloud(output: "Here are some options", recovery: "Still some options")
    let chat = LocalChatViewModel(engine: SelectionTestEngine(), selectionEditingSettings: revisionSettings(automatic: true),
      replaceSelection: { _, _ in XCTFail("Invalid recovery must not paste"); return true },
      cloudProviders: CloudProviderRegistry(openAI: provider, anthropic: provider, chatGPT: provider, gemini: provider),
      sessionStore: ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    chat.startTemporaryChat(context: ConversationContext(sourceName: "Word", text: "original"))
    await completeRevisionRequest(chat, cloud: true)
    XCTAssertEqual(provider.requests.count, 2)
    XCTAssertTrue(chat.selectionRevisions.isEmpty)
    XCTAssertTrue(chat.contextNotice?.contains("could not prepare") == true)
  }

  func testRevisionProtocolSeparatesAcknowledgementAndRejectsPartialOrOrdinaryAnswers() {
    let parsed = SelectionRevisionResponse.parse(revisionOutput)
    XCTAssertEqual(parsed?.text, "Hello team, please send the report today.")
    XCTAssertEqual(parsed?.acknowledgement, "Sure—I’ll make it more professional.")
    XCTAssertNil(SelectionRevisionResponse.parse("Here is an explanation."))
    XCTAssertNil(SelectionRevisionResponse.parse(String(revisionOutput.dropLast(5))))
    XCTAssertNil(SelectionRevisionResponse.parse(revisionOutput + " extra text"))
    XCTAssertNil(SelectionRevisionResponse.parse(revisionOutput + revisionOutput))
    XCTAssertNil(SelectionRevisionResponse.parse(revisionOutput.replacingOccurrences(of: "replace_selection", with: "answer")))
    XCTAssertEqual(SelectionRevisionResponse.visibleText("Sure.\n<enigma-rev"), "Sure.\n")
    XCTAssertEqual(SelectionRevisionResponse.visibleText(revisionOutput), parsed?.acknowledgement)
    XCTAssertEqual(SelectionRevisionResponse.visibleText("x <", streaming: false), "x <")
  }

  func testRevisionInstructionsAndDraftAreRequestOnlyAndExcludedFromSearchRefinement() throws {
    var message = ChatMessage(role: .user, content: "Make it shorter")
    message.contexts = [ConversationContext(sourceName: "Word", text: "original")]
    message.selectionEditingEnabled = true
    message.selectionDraft = "My manually edited draft"
    let expanded = ConversationContextPrompt.expand(message)
    XCTAssertTrue(expanded.content.contains(SelectionRevisionResponse.instructions))
    XCTAssertTrue(expanded.content.contains("My manually edited draft"))
    XCTAssertEqual(ConversationContextPrompt.expand(expanded), expanded)
    XCTAssertEqual(message.content, "Make it shorter")
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
    XCTAssertFalse(decoded.selectionEditingEnabled)
    XCTAssertNil(decoded.selectionDraft)
    message.selectionEditingEnabled = false
    XCTAssertFalse(ConversationContextPrompt.expand(message).content.contains(SelectionRevisionResponse.instructions))
  }

  func testManualRevisionAndFollowupUseEditedDraftWithoutAutomaticPaste() async throws {
    let engine = SelectionTestEngine(output: revisionOutput)
    var pastes: [String] = []
    let chat = LocalChatViewModel(engine: engine, selectionEditingSettings: revisionSettings(),
      replaceSelection: { text, _ in pastes.append(text); return true },
      sessionStore: ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    chat.startTemporaryChat(context: ConversationContext(sourceName: "Word", text: "original selection"))
    await completeRevisionRequest(chat)
    let first = try XCTUnwrap(chat.messages.last)
    XCTAssertEqual(chat.selectionDisplayMessage(first).content, "Sure—I’ll make it more professional.")
    XCTAssertEqual(chat.selectionRevisions[first.id]?.text, "Hello team, please send the report today.")
    XCTAssertTrue(pastes.isEmpty)
    chat.updateSelectionRevision(messageID: first.id, text: "My manually edited draft")
    await completeRevisionRequest(chat, prompt: "Make it warmer")
    XCTAssertTrue(engine.lastRequest?.messages.last?.content.contains("My manually edited draft") == true)
    let latest = try XCTUnwrap(chat.messages.last)
    await chat.applySelectionRevision(messageID: latest.id)
    await chat.applySelectionRevision(messageID: latest.id)
    XCTAssertEqual(pastes, ["Hello team, please send the report today."])
    XCTAssertEqual(chat.selectionRevisions[latest.id]?.status, .sent)
    chat.newChat()
    XCTAssertTrue(chat.selectionRevisions.isEmpty)
  }

  func testAutomaticCloudRevisionAppliesOnlyPayloadAndHidesTheCard() async throws {
    let pasted = expectation(description: "automatic payload applied")
    let provider = SelectionTestCloud(output: revisionOutput)
    let context = ConversationContext(sourceName: "Google Chrome", text: "original")
    let chat = LocalChatViewModel(engine: SelectionTestEngine(), selectionEditingSettings: revisionSettings(automatic: true),
      replaceSelection: { text, id in
        XCTAssertEqual(text, "Hello team, please send the report today.")
        XCTAssertEqual(id, context.id)
        pasted.fulfill(); return true
      }, cloudProviders: CloudProviderRegistry(openAI: provider, anthropic: provider, chatGPT: provider, gemini: provider),
      sessionStore: ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    chat.startTemporaryChat(context: context)
    await completeRevisionRequest(chat, cloud: true)
    await fulfillment(of: [pasted], timeout: 3)
    let revision = try XCTUnwrap(chat.selectionRevisions.values.first)
    XCTAssertTrue(revision.automatic)
    XCTAssertEqual(revision.status, .sent)
    XCTAssertTrue(provider.requests.last?.messages.last?.content.contains(SelectionRevisionResponse.instructions) == true)
  }

  func testSearchRefinementReceivesManualRevisionWithoutEditingProtocol() async throws {
    let provider = SelectionTestCloud(output: revisionOutput)
    let chat = LocalChatViewModel(engine: SelectionTestEngine(), selectionEditingSettings: revisionSettings(),
      replaceSelection: { _, _ in XCTFail("Manual preview must not paste"); return true },
      cloudProviders: CloudProviderRegistry(openAI: provider, anthropic: provider, chatGPT: provider, gemini: provider),
      webSearch: SelectionTestSearch(),
      sessionStore: ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    chat.startTemporaryChat(context: ConversationContext(sourceName: "Word", text: "original"))
    await completeRevisionRequest(chat, cloud: true)
    let message = try XCTUnwrap(chat.messages.last)
    chat.updateSelectionRevision(messageID: message.id, text: "Manually revised claims about the Moon")
    await completeRevisionRequest(chat, prompt: "Rewrite this using verified facts", cloud: true, search: true)
    let query = try XCTUnwrap(provider.requests.first { $0.messages.last?.content.contains("Create one concise web search query") == true })
    XCTAssertTrue(query.messages.last?.content.contains("Manually revised claims about the Moon") == true)
    XCTAssertFalse(query.messages.last?.content.contains(SelectionRevisionResponse.instructions) == true)
  }

  func testAutomaticModeNeverAppliesOrdinaryPartialOrFailedResponses() async {
    for (output, fail) in [("An explanation of the selection.", false), (String(revisionOutput.dropLast(5)), false), (revisionOutput, true)] {
      let chat = LocalChatViewModel(engine: SelectionTestEngine(output: output, fail: fail), selectionEditingSettings: revisionSettings(automatic: true),
        replaceSelection: { _, _ in XCTFail("Only a successfully completed revision may paste"); return true },
        sessionStore: ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
      chat.startTemporaryChat(context: ConversationContext(sourceName: "Word", text: "original"))
      await completeRevisionRequest(chat)
      XCTAssertTrue(chat.selectionRevisions.isEmpty)
    }
  }

  func testCancelledResponseCannotCreateRevisionEvenIfPayloadAlreadyStreamed() async {
    let engine = SelectionTestEngine(output: revisionOutput, hold: true)
    let chat = LocalChatViewModel(engine: engine, selectionEditingSettings: revisionSettings(automatic: true),
      replaceSelection: { _, _ in XCTFail("Cancelled response must not paste"); return true },
      sessionStore: ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    chat.startTemporaryChat(context: ConversationContext(sourceName: "Word", text: "original"))
    let streamed = expectation(description: "payload streamed")
    let observation = chat.$hasReceivedResponse.dropFirst().sink { if $0 { streamed.fulfill() } }
    chat.submit("Rewrite this")
    await fulfillment(of: [streamed], timeout: 3)
    observation.cancel()
    let task = chat.stopStreaming()
    engine.finishHeldStream()
    await task?.value
    XCTAssertTrue(chat.selectionRevisions.isEmpty)
  }

  func testEnablingAutomaticModeMidResponseDoesNotApplyThatResponse() async throws {
    let settings = revisionSettings()
    let engine = SelectionTestEngine(output: revisionOutput, hold: true)
    let chat = LocalChatViewModel(engine: engine, selectionEditingSettings: settings,
      replaceSelection: { _, _ in XCTFail("Enabling auto must not apply an already-started response"); return true },
      sessionStore: ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    chat.startTemporaryChat(context: ConversationContext(sourceName: "Word", text: "original"))
    let streamed = expectation(description: "streaming before setting changes")
    let done = expectation(description: "completed after setting changes")
    let observation = chat.$hasReceivedResponse.dropFirst().sink { if $0 { streamed.fulfill() } }
    let completion = chat.$activeRequest.dropFirst().sink { if $0 == nil { done.fulfill() } }
    chat.submit("Rewrite this")
    await fulfillment(of: [streamed], timeout: 3)
    settings.automaticallyReplace = true
    engine.finishHeldStream()
    await fulfillment(of: [done], timeout: 3)
    observation.cancel(); completion.cancel()
    XCTAssertFalse(try XCTUnwrap(chat.selectionRevisions.values.first).automatic)
  }

  func testRemovedSelectionCannotProduceAnAutomaticRevision() async {
    let engine = SelectionTestEngine(output: revisionOutput, hold: true)
    let chat = LocalChatViewModel(engine: engine, selectionEditingSettings: revisionSettings(automatic: true),
      replaceSelection: { _, _ in XCTFail("Removed context must not paste"); return true },
      sessionStore: ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    let context = ConversationContext(sourceName: "Word", text: "original")
    chat.startTemporaryChat(context: context)
    let streamed = expectation(description: "stream before context removal")
    let done = expectation(description: "finish after context removal")
    let observation = chat.$hasReceivedResponse.dropFirst().sink { if $0 { streamed.fulfill() } }
    let completion = chat.$activeRequest.dropFirst().sink { if $0 == nil { done.fulfill() } }
    chat.submit("Rewrite this")
    await fulfillment(of: [streamed], timeout: 3)
    chat.removeContext(id: context.id)
    engine.finishHeldStream()
    await fulfillment(of: [done], timeout: 3)
    observation.cancel(); completion.cancel()
    XCTAssertTrue(chat.selectionRevisions.isEmpty)
  }

  func testAutomaticSettingDefaultsOffAndPersistsChoice() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let settings = SelectionEditingSettings(defaults: defaults)
    XCTAssertFalse(settings.automaticallyReplace)
    settings.automaticallyReplace = true
    XCTAssertTrue(SelectionEditingSettings(defaults: defaults).automaticallyReplace)
  }

  func testSelectionFallsBackFromEmptyAXTextWithoutReplacingValidText() {
    XCTAssertEqual(SelectionCapturePolicy.preferredText("", rangeText: { "selected range" }), "selected range")
    XCTAssertEqual(SelectionCapturePolicy.preferredText(" \n", rangeText: { "range" }), "range")
    XCTAssertEqual(SelectionCapturePolicy.preferredText("Selected text", rangeText: {
      XCTFail("A valid AX selection must not be replaced by another source"); return nil
    }), "Selected text")
    XCTAssertNil(SelectionCapturePolicy.preferredText(nil, rangeText: { nil }))
  }

  func testValueFallbackUsesOnlyTheSelectedUTF16Range() {
    XCTAssertEqual(SelectionCapturePolicy.text(in: "A😀 selected tail", range: CFRange(location: 4, length: 8)), "selected")
    XCTAssertNil(SelectionCapturePolicy.text(in: "private text", range: CFRange(location: 0, length: 0)))
    XCTAssertNil(SelectionCapturePolicy.text(in: "short", range: CFRange(location: 1, length: Int.max)))
    XCTAssertNil(SelectionCapturePolicy.text(in: "short", range: CFRange(location: -1, length: 2)))
    XCTAssertNil(SelectionCapturePolicy.text(in: nil, range: CFRange(location: 0, length: 3)))
  }

  func testLazyAccessibilityReadinessHasABoundedLongerRetryWindow() async {
    var reads = 0
    let result = await SelectionCaptureRetry.first(attempts: 10, mayContinue: { true }, read: {
      reads += 1
      return reads == 6 ? "focused editor" : nil
    }, wait: {})
    XCTAssertEqual(result, "focused editor")
    XCTAssertEqual(reads, 6)
  }

  func testCaptureRetriesReadinessButStopsOnSourceChange() async {
    var reads = 0
    var waits = 0
    let value: String? = await SelectionCaptureRetry.first(mayContinue: { true }, read: {
      reads += 1; return reads == 2 ? "selected text" : nil
    }, wait: { waits += 1 })
    XCTAssertEqual(value, "selected text")
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(waits, 1)
    var unchanged = true
    reads = 0
    let missing: String? = await SelectionCaptureRetry.first(mayContinue: { unchanged }, read: {
      reads += 1; return nil
    }, wait: { unchanged = false })
    XCTAssertNil(missing)
    XCTAssertEqual(reads, 1)
    reads = 0
    let absent: String? = await SelectionCaptureRetry.first(mayContinue: { true }, read: { reads += 1; return nil }, wait: {})
    XCTAssertNil(absent)
    XCTAssertEqual(reads, 3)
  }

  func testRevisionCardRendersAcknowledgementSeparateFromEditableDraft() throws {
    let revision = SelectionRevision(id: UUID(), contextID: UUID(), text: "Hello team,\n\nCould you please send the report today? Thank you for your help.", automatic: false)
    let view = VStack(alignment: .leading, spacing: 16) {
      Text("Sure—I’ll make it more professional.")
      SelectionRevisionCard(revision: revision, disabled: false, update: { _ in }, replace: {})
    }.padding(24).frame(width: 560).background(Color(red: 0.09, green: 0.13, blue: 0.11)).preferredColorScheme(.dark)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(host.frame.height, 180)
    XCTAssertLessThan(host.frame.height, 440)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/selection-revision-card.png"))
  }

  func testPasteUsesRememberedPIDAndCurrentSelectionThenRestoresAllClipboardItems() async throws {
    let board = NSPasteboard(name: .init(UUID().uuidString))
    defer { board.releaseGlobally() }
    let rich = NSPasteboardItem()
    rich.setString("original clipboard", forType: .string)
    rich.setData(Data("{\\rtf1 preserved}".utf8), forType: .rtf)
    let file = NSPasteboardItem()
    file.setString("file:///tmp/preserved.txt", forType: .fileURL)
    board.writeObjects([rich, file])
    let original = try XCTUnwrap(SelectionPasteboardSnapshot(board))
    let editor = NSTextView()
    editor.string = "Originally selected. Now selected."
    editor.setSelectedRange((editor.string as NSString).range(of: "Now selected"))
    var operations: [String] = []
    let result = await SelectionPasteTransaction.perform(text: "replacement", pid: 1234, board: board,
      isAvailable: { true }, activate: { operations.append("activate"); return true },
      isSafeToPaste: { operations.append("password check"); return true }, postPaste: { pid in
        XCTAssertEqual(pid, 1234)
        XCTAssertNotNil(board.data(forType: .init("org.nspasteboard.TransientType")))
        XCTAssertNotNil(board.data(forType: .init("org.nspasteboard.AutoGeneratedType")))
        editor.insertText(board.string(forType: .string)!, replacementRange: editor.selectedRange())
        operations.append("paste")
        return true
      }, settle: {
        XCTAssertEqual(board.string(forType: .string), "replacement")
        operations.append("settle")
      })
    XCTAssertEqual(result, .sent)
    XCTAssertEqual(editor.string, "Originally selected. replacement.")
    XCTAssertEqual(operations, ["activate", "password check", "paste", "settle"])
    XCTAssertEqual(SelectionPasteboardSnapshot(board)?.items, original.items)
  }

  func testPasteAllowsCurrentInsertionPointWithoutOriginalRangeOrDocument() async {
    let board = NSPasteboard(name: .init(UUID().uuidString))
    defer { board.releaseGlobally() }
    let editor = NSTextView()
    editor.string = "New document: "
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    let result = await SelectionPasteTransaction.perform(text: "hello", pid: 42, board: board,
      isAvailable: { true }, activate: { true }, isSafeToPaste: { true }, postPaste: { _ in
        editor.insertText(board.string(forType: .string)!, replacementRange: editor.selectedRange())
        return true
      }, settle: {})
    XCTAssertEqual(result, .sent)
    XCTAssertEqual(editor.string, "New document: hello")
    XCTAssertTrue(board.pasteboardItems?.isEmpty ?? true)
  }

  func testUnavailablePermissionOrTerminatedSourceDoesNotActivateOrTouchClipboard() async {
    let board = NSPasteboard(name: .init(UUID().uuidString))
    defer { board.releaseGlobally() }
    board.setString("keep", forType: .string)
    let count = board.changeCount
    let result = await SelectionPasteTransaction.perform(text: "new", pid: 1, board: board,
      isAvailable: { false }, activate: { XCTFail("Must not activate"); return true },
      isSafeToPaste: { XCTFail("Must not inspect source"); return true },
      postPaste: { _ in XCTFail("Must not paste"); return true }, settle: { XCTFail("Must not wait") })
    XCTAssertEqual(result, .unavailable)
    XCTAssertEqual(board.changeCount, count)
  }

  func testFailedActivationAndPasswordFocusPreventPasteWithoutTouchingClipboard() async {
    for activates in [false, true] {
      let board = NSPasteboard(name: .init(UUID().uuidString))
      defer { board.releaseGlobally() }
      board.setString("keep", forType: .string)
      let count = board.changeCount
      let result = await SelectionPasteTransaction.perform(text: "new", pid: 1, board: board,
        isAvailable: { true }, activate: { activates }, isSafeToPaste: { false },
        postPaste: { _ in XCTFail("Must not paste"); return true }, settle: { XCTFail("Must not wait") })
      XCTAssertEqual(result, .unavailable)
      XCTAssertEqual(board.changeCount, count)
    }
  }

  func testSecureInputOrPermissionRevocationDuringActivationPreventsPaste() async {
    let board = NSPasteboard(name: .init(UUID().uuidString))
    defer { board.releaseGlobally() }
    var available = true
    let result = await SelectionPasteTransaction.perform(text: "new", pid: 1, board: board,
      isAvailable: { available }, activate: { available = false; return true }, isSafeToPaste: { true },
      postPaste: { _ in XCTFail("Must not paste"); return true }, settle: {})
    XCTAssertEqual(result, .unavailable)
  }

  func testUnobservablePasteIsSentOnlyOnceAndNewClipboardCopyWins() async {
    let board = NSPasteboard(name: .init(UUID().uuidString))
    defer { board.releaseGlobally() }
    board.setString("old", forType: .string)
    var pastes = 0
    let result = await SelectionPasteTransaction.perform(text: "new", pid: 9, board: board,
      isAvailable: { true }, activate: { true }, isSafeToPaste: { true },
      postPaste: { _ in pastes += 1; return true }, settle: {
        board.clearContents()
        board.setString("user copied something else", forType: .string)
      })
    XCTAssertEqual(result, .sent)
    XCTAssertEqual(pastes, 1)
    XCTAssertEqual(board.string(forType: .string), "user copied something else")
  }

  func testEventCreationFailureRestoresClipboardWithoutRetry() async {
    let board = NSPasteboard(name: .init(UUID().uuidString))
    defer { board.releaseGlobally() }
    board.setString("keep", forType: .string)
    var attempts = 0
    let result = await SelectionPasteTransaction.perform(text: "new", pid: 1, board: board,
      isAvailable: { true }, activate: { true }, isSafeToPaste: { true },
      postPaste: { _ in attempts += 1; return false }, settle: { XCTFail("No event was posted") })
    XCTAssertEqual(result, .eventUnavailable)
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(board.string(forType: .string), "keep")
  }

  func testSelectionExpansionAnchorsToComposerAndFitsDisplays() {
    let visible = NSRect(x: -1440, y: 40, width: 1440, height: 860)
    let composer = NSRect(x: -1200, y: 100, width: 720, height: 80)
    let expanded = SelectionPanelExpansion.frame(from: composer, visible: visible)
    XCTAssertEqual(expanded.minY, composer.minY)
    XCTAssertEqual(expanded.minX, composer.minX)
    XCTAssertEqual(expanded.width, composer.width)
    XCTAssertTrue(visible.contains(expanded))
    let edge = SelectionPanelExpansion.frame(from: NSRect(x: -730, y: 820, width: 720, height: 80), visible: visible)
    XCTAssertEqual(edge.maxY, visible.maxY)
    XCTAssertTrue(visible.contains(edge))
    let small = NSRect(x: 0, y: 0, width: 700, height: 500)
    XCTAssertTrue(small.contains(SelectionPanelExpansion.frame(from: composer, visible: small)))
    XCTAssertEqual(SelectionPanelExpansion.progress(at: 0), 0)
    XCTAssertGreaterThan(SelectionPanelExpansion.progress(at: 0.3), 1)
    XCTAssertEqual(SelectionPanelExpansion.progress(at: 1), 1)
  }

  func testSelectionPanelHideSettlesExpansionAndNewChatRestoresNormalSize() throws {
    let field = NSTextField(string: "Draft")
    let controller = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(), contentView: field)
    controller.show()
    defer { controller.hide() }
    let window = try XCTUnwrap(field.window)
    let original = window.frame
    let visible = try XCTUnwrap(window.screen?.visibleFrame)
    controller.presentSelectionContext(nil, cursor: NSPoint(x: visible.midX, y: visible.minY + 100), selection: nil, visible: visible)
    XCTAssertTrue(controller.isSelectionComposer)
    XCTAssertLessThan(window.frame.height, 150)
    controller.expandSelectionPanel()
    controller.hide()
    XCTAssertFalse(controller.isSelectionComposer)
    XCTAssertEqual(window.frame.height, min(600, visible.height))
    NotificationCenter.default.post(name: .newChatRequested, object: nil)
    XCTAssertEqual(window.frame, original)
  }

  func testReducedMotionExpandsImmediatelyAndRepeatedSendDoesNotResizeAgain() throws {
    let field = NSTextField(string: "Draft")
    let controller = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(), contentView: field, reduceMotion: { true })
    controller.show()
    defer { controller.hide() }
    let window = try XCTUnwrap(field.window)
    let visible = try XCTUnwrap(window.screen?.visibleFrame)
    controller.presentSelectionContext(nil, cursor: NSPoint(x: visible.midX, y: visible.minY + 100), selection: nil, visible: visible)
    let expected = SelectionPanelExpansion.frame(from: window.frame, visible: visible)
    controller.expandSelectionPanel()
    XCTAssertEqual(window.frame, expected)
    XCTAssertFalse(controller.isSelectionComposer)
    controller.expandSelectionPanel()
    XCTAssertEqual(window.frame, expected)
    XCTAssertTrue(window.isVisible)
  }

  func testSelectionComposerExpandsOnlyAfterAcceptedPromptAndRenders() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: WelcomeSetup.completedKey)
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    defaults.set(ChatMode.local.rawValue, forKey: StartPreferences.modeKey)
    defer {
      try? FileManager.default.removeItem(at: directory)
      UserDefaults().removePersistentDomain(forName: suite)
    }
    let engine = SelectionTestEngine(output: "The highlighted passage asks the team to send a report today.", hold: true)
    let chat = LocalChatViewModel(engine: engine, sessionStore: ChatSessionStore(applicationSupportDirectory: directory))
    await chat.refreshInstalledModel()
    let advisor = LocalModelAdvisor(directory: directory, modelsDirectory: directory, defaults: defaults, trust: nil)
    await advisor.start(installedModels: [try XCTUnwrap(chat.installedModel)], presentOnboarding: false)
    let screen = ScreenComposerCoordinator()
    let appearance = GlassAppearanceSettings(defaults: defaults)
    let view = NSHostingView(rootView: AppShellView(glassAppearance: appearance, localChat: chat,
      screen: screen, modelAdvisor: advisor, startPreferences: StartPreferences(defaults: defaults),
      welcomeSetup: WelcomeSetup(defaults: defaults)))
    let controller = SpotlightPanelController(glassAppearance: appearance, contentView: view)
    controller.show()
    defer { chat.stopStreaming(); engine.finishHeldStream(); controller.hide() }
    try await Task.sleep(for: .milliseconds(200))
    let window = try XCTUnwrap(view.window)
    let visible = try XCTUnwrap(window.screen?.visibleFrame)
    controller.presentSelectionContext(ConversationContext(sourceName: "Test editor", text: "Please send the report today."),
      cursor: NSPoint(x: visible.midX, y: visible.minY + 120), selection: nil, visible: visible)
    try await Task.sleep(for: .milliseconds(250))
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(controller.isSelectionComposer)
    XCTAssertLessThan(window.frame.height, 150)
    XCTAssertTrue(chat.isTemporaryChat)
    XCTAssertEqual(chat.attachedContexts.count, 1)
    func descendants(_ node: NSView) -> [NSView] { [node] + node.subviews.flatMap(descendants) }
    let editor = try XCTUnwrap(descendants(view).compactMap { $0 as? SlashCommandTextView }.first)
    XCTAssertTrue(view.bounds.contains(view.convert(editor.bounds, from: editor)))
    func render(_ name: String) throws {
      view.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "/tmp/Enigma-selection-\(name).png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "Selection \(name)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    try render("composer")
    let previewData = try Data(contentsOf: URL(fileURLWithPath: "/tmp/Enigma-selection-composer.png"))
    let previewImage = try XCTUnwrap(NSBitmapImageRep(data: previewData)?.cgImage)
    let previewText = try await ScreenOCRService().recognize(previewImage).text.lowercased()
    XCTAssertTrue(previewText.contains("please send the report today"), "The selected text must be visible before sending: \(previewText)")
    // Empty input must not expand or create a request.
    editor.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
    XCTAssertTrue(controller.isSelectionComposer)
    XCTAssertNil(chat.activeRequest)
    screen.draft = "Explain this passage"
    try await Task.sleep(for: .milliseconds(50))
    editor.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertFalse(controller.isSelectionComposer)
    XCTAssertGreaterThan(window.frame.height, 420)
    XCTAssertTrue(visible.contains(window.frame))
    XCTAssertEqual(screen.draft, "")
    XCTAssertTrue(engine.lastRequest?.prompt.contains("Please send the report today.") == true)
    try render("conversation")
    controller.presentSelectionContext(nil, cursor: NSPoint(x: visible.midX, y: visible.minY + 120), selection: nil, visible: visible)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(controller.isSelectionComposer)
    XCTAssertLessThan(window.frame.height, 150)
    XCTAssertTrue(chat.messages.isEmpty)
  }

  func testReplacementReleasesPanelAndRestoresTheSameChatWindow() throws {
    let field = NSTextField(string: "Keep this draft")
    let controller = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(), contentView: field)
    controller.show()
    defer { controller.hide() }
    let window = try XCTUnwrap(field.window)
    let frame = window.frame
    NotificationCenter.default.post(name: .selectionReplacementBegan, object: nil)
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
    NotificationCenter.default.post(name: .selectionReplacementEnded, object: nil)
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(field.window === window)
    XCTAssertEqual(window.frame, frame)
    XCTAssertEqual(field.stringValue, "Keep this draft")
  }

  func testAccessibilityRequestOpensSettingsEvenWhenSystemPromptDoesNotGrantAccess() {
    var operations: [String] = []
    let access = SelectionAccessibilityAccess(checkTrust: { false }, prompt: { operations.append("prompt") },
      openSettings: { url in
        XCTAssertEqual(url, SelectionAccessibilityAccess.settingsURL)
        operations.append("settings")
      })
    access.requestAccess()
    XCTAssertEqual(operations, ["prompt", "settings"])
    XCTAssertFalse(access.isGranted)
  }

  func testAccessibilityStateRefreshReflectsGrantAndRevocationWithoutPrompting() {
    var trusted = false
    let access = SelectionAccessibilityAccess(checkTrust: { trusted },
      prompt: { XCTFail("Refresh must not prompt") }, openSettings: { _ in XCTFail("Refresh must not open Settings") })
    trusted = true
    access.refresh()
    XCTAssertTrue(access.isGranted)
    trusted = false
    access.refresh()
    XCTAssertFalse(access.isGranted)
  }

  func testDoubleOptionRequiresTwoShortSoloTaps() {
    var detector = OptionDoubleTap()
    XCTAssertFalse(detector.flagsChanged(keyCode: 58, modifiers: .option, timestamp: 1))
    XCTAssertFalse(detector.flagsChanged(keyCode: 58, modifiers: [], timestamp: 1.1))
    XCTAssertFalse(detector.flagsChanged(keyCode: 58, modifiers: .option, timestamp: 1.2))
    XCTAssertTrue(detector.flagsChanged(keyCode: 58, modifiers: [], timestamp: 1.3))
    XCTAssertFalse(detector.flagsChanged(keyCode: 58, modifiers: [], timestamp: 1.31))
  }

  func testChordsClicksTypingHoldsAndOtherModifiersCancelOptionTaps() {
    for modifier: NSEvent.ModifierFlags in [.command, .control, .shift, .function, .capsLock] {
      var detector = OptionDoubleTap()
      _ = detector.flagsChanged(keyCode: 58, modifiers: .option, timestamp: 1)
      _ = detector.flagsChanged(keyCode: 58, modifiers: [], timestamp: 1.05)
      _ = detector.flagsChanged(keyCode: 58, modifiers: [.option, modifier], timestamp: 1.1)
      XCTAssertFalse(detector.flagsChanged(keyCode: 58, modifiers: [], timestamp: 1.15))
    }
    var detector = OptionDoubleTap()
    _ = detector.flagsChanged(keyCode: 58, modifiers: .option, timestamp: 1)
    detector.reset() // keyDown, click, or scroll
    XCTAssertFalse(detector.flagsChanged(keyCode: 58, modifiers: [], timestamp: 1.1))
    _ = detector.flagsChanged(keyCode: 58, modifiers: .option, timestamp: 1.2)
    XCTAssertFalse(detector.flagsChanged(keyCode: 58, modifiers: [], timestamp: 1.6))
    _ = detector.flagsChanged(keyCode: 58, modifiers: .option, timestamp: 2)
    _ = detector.flagsChanged(keyCode: 58, modifiers: [], timestamp: 2.1)
    _ = detector.flagsChanged(keyCode: 61, modifiers: .option, timestamp: 2.8)
    XCTAssertFalse(detector.flagsChanged(keyCode: 61, modifiers: [], timestamp: 2.9))
  }

  func testBothOptionKeysHeldTogetherCannotActivate() {
    var detector = OptionDoubleTap()
    _ = detector.flagsChanged(keyCode: 58, modifiers: .option, timestamp: 1)
    _ = detector.flagsChanged(keyCode: 61, modifiers: .option, timestamp: 1.1)
    _ = detector.flagsChanged(keyCode: 58, modifiers: .option, timestamp: 1.2)
    XCTAssertFalse(detector.flagsChanged(keyCode: 61, modifiers: [], timestamp: 1.3))
  }

  func testCopyFallbackDistinguishesBrowserCanvasAndNativeEmptySelection() {
    let empty = CFRange(location: 0, length: 0)
    XCTAssertTrue(SelectionCapturePolicy.allowsCopy(range: empty, bundleID: "com.google.Chrome"))
    XCTAssertFalse(SelectionCapturePolicy.allowsCopy(range: empty, bundleID: "com.apple.Notes"))
    XCTAssertFalse(SelectionCapturePolicy.allowsCopy(range: empty, bundleID: "com.microsoft.VSCode"))
    XCTAssertFalse(SelectionCapturePolicy.allowsCopy(range: nil, bundleID: "com.jetbrains.pycharm"))
    XCTAssertTrue(SelectionCapturePolicy.allowsCopy(range: CFRange(location: 1, length: 2), bundleID: "com.microsoft.VSCode"))
  }

  func testAlternateConfiguredModifierUsesItsOwnKeyCodes() {
    var detector = OptionDoubleTap()
    detector.modifier = .shift
    XCTAssertFalse(detector.flagsChanged(keyCode: 58, modifiers: .option, timestamp: 1))
    _ = detector.flagsChanged(keyCode: 56, modifiers: .shift, timestamp: 2)
    _ = detector.flagsChanged(keyCode: 56, modifiers: [], timestamp: 2.05)
    _ = detector.flagsChanged(keyCode: 56, modifiers: .shift, timestamp: 2.1)
    XCTAssertTrue(detector.flagsChanged(keyCode: 56, modifiers: [], timestamp: 2.15))
  }

  func testPlacementFitsNegativeCoordinateDisplayAndAvoidsSelection() {
    let display = NSRect(x: -1600, y: -400, width: 1600, height: 1000)
    let selection = NSRect(x: -850, y: 200, width: 80, height: 30)
    let result = SelectionPanelPlacement.frame(size: NSSize(width: 640, height: 420),
      cursor: selection.origin, selection: selection, visible: display)
    XCTAssertTrue(display.contains(result))
    XCTAssertFalse(result.intersects(selection))
    let tiny = NSRect(x: 100, y: 100, width: 480, height: 320)
    let fitted = SelectionPanelPlacement.frame(size: NSSize(width: 1200, height: 780),
      cursor: NSPoint(x: 575, y: 415), selection: nil, visible: tiny)
    XCTAssertEqual(fitted, tiny)
  }

  func testClipboardPreservesAllItemsAndRepresentations() throws {
    let board = NSPasteboard(name: .init("SelectionTests-\(UUID())"))
    defer { board.releaseGlobally() }
    let first = NSPasteboardItem()
    first.setString("existing clipboard", forType: .string)
    let rich = NSAttributedString(string: "Rich clipboard text")
    first.setData(try rich.data(from: NSRange(location: 0, length: rich.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
    let second = NSPasteboardItem()
    let pixels = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
    second.setData(try XCTUnwrap(pixels.representation(using: .png, properties: [:])), forType: .png)
    board.writeObjects([first, second])
    let snapshot = try XCTUnwrap(SelectionPasteboardSnapshot(board))
    board.clearContents()
    board.setString("temporary selection", forType: .string)
    snapshot.restore(board, ifUnchanged: board.changeCount)
    XCTAssertEqual(SelectionPasteboardSnapshot(board)?.items, snapshot.items)
    let count = board.changeCount
    board.clearContents()
    board.setString("new user copy", forType: .string)
    snapshot.restore(board, ifUnchanged: count)
    XCTAssertEqual(board.string(forType: .string), "new user copy")
  }

  func testEmptyClipboardRestoresToEmpty() throws {
    let board = NSPasteboard(name: .init("SelectionTests-\(UUID())"))
    defer { board.releaseGlobally() }
    board.clearContents()
    let snapshot = try XCTUnwrap(SelectionPasteboardSnapshot(board))
    board.setString("temporary", forType: .string)
    snapshot.restore(board, ifUnchanged: board.changeCount)
    XCTAssertTrue(board.pasteboardItems?.isEmpty ?? true)
  }

  func testContextIsBudgetedWithoutChangingPromptOrSerializingSourceText() throws {
    var message = ChatMessage(role: .user, content: "Explain this")
    message.contexts = [ConversationContext(sourceName: "Google Chrome", text: "A selected passage")]
    let prepared = try ChatContextPreparer.prepare([message],
      budget: ContextBudget(contextWindow: 4096, outputTokens: 512, overheadTokens: 256),
      countTokens: { $0.reduce(0) { $0 + $1.content.utf8.count } })
    XCTAssertTrue(prepared.messages[0].content.contains("A selected passage"))
    XCTAssertTrue(prepared.messages[0].content.contains("untrusted source material"))
    XCTAssertEqual(message.content, "Explain this")
    XCTAssertEqual(ConversationContextPrompt.expand(prepared.messages[0]), prepared.messages[0])
    let data = try JSONEncoder().encode(message)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("A selected passage"))
    XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: data).contexts)
    XCTAssertThrowsError(try ChatContextPreparer.prepare([message],
      budget: ContextBudget(contextWindow: 100, outputTokens: 50, overheadTokens: 20),
      countTokens: { $0.reduce(0) { $0 + $1.content.utf8.count } }))
  }

  func testTemporaryChatKeepsFiveSavedChatsAndFollowupContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let sessions = (1...5).map { ChatSession(title: "Saved \($0)", messages: [ChatMessage(role: .user, content: "Keep me")]) }
    try store.save(sessions)
    let savedData = try Data(contentsOf: root.appendingPathComponent("chats.json"))
    let engine = SelectionTestEngine()
    let chat = LocalChatViewModel(engine: engine, sessionStore: store)
    await chat.refreshInstalledModel()
    let context = ConversationContext(sourceName: "Notes", text: "Test selected text")
    chat.startTemporaryChat(context: context)
    let temporaryID = chat.selectedSessionID
    XCTAssertTrue(chat.isTemporaryChat)
    XCTAssertEqual(chat.messages, [])
    XCTAssertEqual(chat.sessions.count, 6)
    for prompt in ["Rewrite this professionally", "Make it shorter"] {
      let done = expectation(description: prompt)
      var observation: AnyCancellable?
      observation = chat.$activeRequest.dropFirst().sink { active in if active == nil { done.fulfill() } }
      chat.submit(prompt)
      await fulfillment(of: [done], timeout: 3)
      observation?.cancel()
      XCTAssertTrue(engine.lastRequest?.prompt.contains(context.text) == true)
      XCTAssertEqual(chat.messages.filter { $0.role == .user }.last?.content, prompt)
    }
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("chats.json")), savedData)
    chat.removeContext(id: context.id)
    XCTAssertEqual(chat.attachedContexts, [])
    chat.startTemporaryChat(context: nil)
    XCTAssertNotEqual(chat.selectedSessionID, temporaryID)
    XCTAssertTrue(chat.messages.isEmpty)
    XCTAssertEqual(chat.sessions.count, 6)
    chat.selectSession(id: sessions[0].id)
    XCTAssertFalse(chat.isTemporaryChat)
    XCTAssertEqual(chat.sessions.count, 5)
    XCTAssertEqual(chat.messages.first?.content, "Keep me")
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("chats.json")), savedData)
  }

  func testCloudAndSearchReceiveContextWhileUserMessagesStayNatural() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = SelectionTestCloud()
    let search = SelectionTestSearch()
    let chat = LocalChatViewModel(engine: SelectionTestEngine(),
      cloudProviders: CloudProviderRegistry(openAI: provider, anthropic: provider, chatGPT: provider, gemini: provider),
      webSearch: search, sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    let context = ConversationContext(sourceName: "Safari", text: "The Moon is made of cheese.")
    chat.startTemporaryChat(context: context)
    for enabled in [false, true] {
      let done = expectation(description: "cloud completed")
      let observation = chat.$activeRequest.dropFirst().sink { active in if active == nil { done.fulfill() } }
      chat.submitCloud("Verify these claims", provider: .chatGPT, modelID: "fixture", searchEnabled: enabled)
      await fulfillment(of: [done], timeout: 3)
      observation.cancel()
      XCTAssertEqual(chat.state, .idle)
      XCTAssertTrue(provider.requests.last?.messages.last?.content.contains(context.text) == true)
      XCTAssertEqual(chat.messages.filter { $0.role == .user }.last?.content, "Verify these claims")
    }
    let queries = await search.queries
    XCTAssertEqual(queries, ["Moon composition evidence"])
    XCTAssertTrue(provider.requests.contains { $0.messages.last?.content.contains("Create one concise web search query") == true })
    chat.removeContext(id: context.id)
    let done = expectation(description: "removed context")
    let observation = chat.$activeRequest.dropFirst().sink { active in if active == nil { done.fulfill() } }
    chat.submitCloud("Another question", provider: .chatGPT, modelID: "fixture")
    await fulfillment(of: [done], timeout: 3)
    observation.cancel()
    XCTAssertFalse(provider.requests.last?.messages.contains { $0.content.contains(context.text) } == true)
  }

  func testContextCardRendersWithoutTruncatingControls() throws {
    let card = SelectionContextCard(context: ConversationContext(sourceName: "Google Chrome",
      text: "The selected passage stays attached as context. Ask a follow-up question naturally, or remove the selection using the close button."), remove: {})
      .padding(16).frame(width: 520).background(Color(red: 0.09, green: 0.13, blue: 0.11)).preferredColorScheme(.dark)
    let host = NSHostingView(rootView: card)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(host.frame.height, 65)
    XCTAssertLessThan(host.frame.height, 160)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/selection-context-card.png"))
  }
}

import Combine

private final class SelectionTestEngine: LocalModelEngine, @unchecked Sendable {
  private let output: String
  private let recovery: String
  private let fail: Bool
  private let hold: Bool
  private var held: AsyncThrowingStream<String, Error>.Continuation?
  init(output: String = "Transformed text", fail: Bool = false, hold: Bool = false, recovery: String = "{\"operation\":\"answer\"}") {
    self.recovery = recovery; self.output = output; self.fail = fail; self.hold = hold
  }
  func finishHeldStream() { lock.withLock { held?.finish(); held = nil } }
  private let lock = NSLock()
  private var requests: [LocalModelRequest] = []
  var lastRequest: LocalModelRequest? { lock.withLock { requests.last } }
  func installedModel() async -> LocalModel? { LocalModel(id: "selection-fixture", displayName: "Fixture", fileURL: URL(fileURLWithPath: "/tmp/fixture.gguf")) }
  func installedModels() async -> [LocalModel] { [await installedModel()!] }
  func install(_ model: LocalModel) async throws { }
  func selectModel(id: String) async throws { }
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel { throw LocalInferenceError.invalidModelFile }
  func unload() async { }
  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    lock.withLock { requests.append(request) }
    return AsyncThrowingStream { continuation in
      continuation.yield(request.prompt.contains(SelectionRevisionResponse.recoveryInstructions) ? recovery : output)
      if hold { lock.withLock { held = continuation } }
      else if fail { continuation.finish(throwing: LocalInferenceError.invalidModelFile) }
      else { continuation.finish() }
    }
  }
}

private final class SelectionTestCloud: ChatProvider, @unchecked Sendable {
  private let output: String
  private let recovery: String
  init(output: String = "A normal response", recovery: String = "{\"operation\":\"answer\"}") { self.output = output; self.recovery = recovery }
  private let lock = NSLock()
  private var stored: [ChatRequest] = []
  var requests: [ChatRequest] { lock.withLock { stored } }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    lock.withLock { stored.append(request) }
    let query = request.messages.last?.content.contains("Create one concise web search query") == true
    return AsyncThrowingStream { continuation in
      continuation.yield(.token(query ? "Moon composition evidence" : request.messages.last?.content.contains(SelectionRevisionResponse.recoveryInstructions) == true ? recovery : output))
      continuation.yield(.completed)
      continuation.finish()
    }
  }
}

private actor SelectionTestSearch: WebSearchProvider {
  var queries: [String] = []
  func search(_ query: String, maximumTokens: Int) async throws -> [WebSearchResult] {
    queries.append(query)
    return [WebSearchResult(source: WebSearchSource(title: "Lunar evidence", url: URL(string: "https://example.com/moon")!),
      snippets: ["The Moon is made of rock."])]
  }
}
