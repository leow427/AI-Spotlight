import AppKit
import SwiftUI
import XCTest
@testable import PrimaryAgent

@MainActor
final class SelectionContextTests: XCTestCase {
  func testCopiedBrowserSelectionNeverReusesHiddenPlaceholderRange() {
    let placeholder = CFRange(location: 0, length: 1)
    XCTAssertNil(SelectionReplacementPolicy.rangeForReplacement(placeholder, usedCopy: true, hasWebDocument: true))
    XCTAssertNil(SelectionReplacementPolicy.rangeForReplacement(CFRange(location: 0, length: 0), usedCopy: true, hasWebDocument: true))
    XCTAssertEqual(SelectionReplacementPolicy.rangeForReplacement(placeholder, usedCopy: false, hasWebDocument: true)?.length, 1)
    XCTAssertEqual(SelectionReplacementPolicy.rangeForReplacement(placeholder, usedCopy: true, hasWebDocument: false)?.length, 1)
  }

  func testCanvasAnchorRequiresCopiedSelectionAndIdentifiedEditableDocument() {
    for url in ["https://docs.google.com/document/d/test/edit", "https://mail.google.com/mail/u/0/#drafts/test", "file:///tmp/test.html"] {
      XCTAssertTrue(SelectionReplacementPolicy.allowsCopyAnchor(hasRange: false, copiedText: "selected words",
        hasDocument: true, documentURL: url, editable: true))
    }
    for url: String? in [nil, "", "about:blank", "javascript:void(0)"] {
      XCTAssertFalse(SelectionReplacementPolicy.allowsCopyAnchor(hasRange: false, copiedText: "selected words",
        hasDocument: true, documentURL: url, editable: true))
    }
    for copied: String? in [nil, "", " \n\u{00a0}"] {
      XCTAssertFalse(SelectionReplacementPolicy.allowsCopyAnchor(hasRange: false, copiedText: copied,
        hasDocument: true, documentURL: "https://docs.google.com/document/d/test/edit", editable: true))
    }
    XCTAssertFalse(SelectionReplacementPolicy.allowsCopyAnchor(hasRange: false, copiedText: "words",
      hasDocument: false, documentURL: "https://example.com", editable: true))
    XCTAssertFalse(SelectionReplacementPolicy.allowsCopyAnchor(hasRange: false, copiedText: "words",
      hasDocument: true, documentURL: "https://example.com", editable: false))
    XCTAssertFalse(SelectionReplacementPolicy.allowsCopyAnchor(hasRange: true, copiedText: "words",
      hasDocument: true, documentURL: "https://example.com", editable: true))
  }

  func testCanvasReverificationAcceptsExactCopyWithoutAnAccessibilityRange() async {
    var copies = 0
    let result = await SelectionCopyVerification.matches(expected: "A document passage 👋", isTargetValid: { true }, copy: {
      copies += 1
      return "A document passage 👋"
    })
    XCTAssertTrue(result)
    XCTAssertEqual(copies, 1)
  }

  func testCanvasReverificationRefusesCopyWhenSourceAlreadyChanged() async {
    let result = await SelectionCopyVerification.matches(expected: "same words", isTargetValid: { false }, copy: {
      XCTFail("Do not copy from an invalidated document, window, or field")
      return "same words"
    })
    XCTAssertFalse(result)
  }

  func testCanvasReverificationRejectsIdenticalTextAfterNavigationOrReselection() async {
    var sourceIsUnchanged = true
    var pasted = false
    let verified = await SelectionCopyVerification.matches(expected: "same words", isTargetValid: { sourceIsUnchanged }, copy: {
      // Navigation, or a click selecting another occurrence, during async copy.
      sourceIsUnchanged = false
      return "same words"
    })
    if verified { pasted = true }
    XCTAssertFalse(pasted)
  }

  func testCanvasReverificationRejectsEmptyChangedOrFailedCopy() async {
    for value: String? in [nil, "", "different", "original "] {
      let verified = await SelectionCopyVerification.matches(expected: "original", isTargetValid: { true }, copy: { value })
      XCTAssertFalse(verified)
    }
  }

  func testVerifiedSelectionReplacesOnlyHighlightedTextInNativeEditorFixture() async {
    let editor = NSTextView()
    editor.string = "Before: hello 👋. After."
    let selection = (editor.string as NSString).range(of: "hello 👋")
    editor.setSelectedRange(selection)
    let expected = (editor.string as NSString).substring(with: selection)
    let verified = await SelectionCopyVerification.matches(expected: expected, isTargetValid: {
      editor.selectedRange() == selection
    }, copy: {
      (editor.string as NSString).substring(with: editor.selectedRange())
    })
    XCTAssertTrue(verified)
    if verified { editor.insertText("goodbye 🌍", replacementRange: editor.selectedRange()) }
    XCTAssertEqual(editor.string, "Before: goodbye 🌍. After.")
    XCTAssertTrue(SelectionReplacementPolicy.confirms(originalValue: "Before: hello 👋. After.", currentValue: editor.string,
      range: CFRange(location: selection.location, length: selection.length), originalSelection: expected, replacement: "goodbye 🌍"))
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

  func testReplacementAcknowledgementRequiresExactExpectedEdit() {
    let range = CFRange(location: 4, length: 5)
    XCTAssertTrue(SelectionReplacementPolicy.confirms(originalValue: "Say hello now", currentValue: "Say goodbye now",
      range: range, originalSelection: "hello", replacement: "goodbye"))
    XCTAssertFalse(SelectionReplacementPolicy.confirms(originalValue: "Say hello now", currentValue: "Say hello now",
      range: range, originalSelection: "hello", replacement: "goodbye"))
    XCTAssertFalse(SelectionReplacementPolicy.confirms(originalValue: "Say hello now", currentValue: "goodbye",
      range: range, originalSelection: "hello", replacement: "goodbye"))
    XCTAssertFalse(SelectionReplacementPolicy.confirms(originalValue: nil, currentValue: "goodbye",
      range: range, originalSelection: "hello", replacement: "goodbye"))
    XCTAssertFalse(SelectionReplacementPolicy.confirms(originalValue: "Say hello now", currentValue: "Say goodbye now",
      range: CFRange(location: 400, length: 5), originalSelection: "hello", replacement: "goodbye"))
    XCTAssertTrue(SelectionReplacementPolicy.confirms(originalValue: "Hi 👋!", currentValue: "Hi 🌍!",
      range: CFRange(location: 3, length: 2), originalSelection: "👋", replacement: "🌍"))
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

  func testExpiredChangedOrEmptyTargetsCannotBeReplaced() {
    let date = Date(timeIntervalSince1970: 1000)
    XCTAssertTrue(SelectionReplacementPolicy.isFresh(capturedAt: date, now: date.addingTimeInterval(299)))
    XCTAssertFalse(SelectionReplacementPolicy.isFresh(capturedAt: date, now: date.addingTimeInterval(300)))
    XCTAssertFalse(SelectionReplacementPolicy.isFresh(capturedAt: date, now: date.addingTimeInterval(-1)))
    let range = CFRange(location: 10, length: 20)
    XCTAssertTrue(SelectionReplacementPolicy.matches(original: range, current: range))
    XCTAssertFalse(SelectionReplacementPolicy.matches(original: range, current: CFRange(location: 11, length: 20)))
    XCTAssertFalse(SelectionReplacementPolicy.matches(original: range, current: CFRange(location: 10, length: 0)))
    XCTAssertFalse(SelectionReplacementPolicy.matches(original: CFRange(location: 0, length: 0), current: CFRange(location: 0, length: 0)))
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
    return AsyncThrowingStream { $0.yield("Transformed text"); $0.finish() }
  }
}

private final class SelectionTestCloud: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [ChatRequest] = []
  var requests: [ChatRequest] { lock.withLock { stored } }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    lock.withLock { stored.append(request) }
    let query = request.messages.last?.content.contains("Create one concise web search query") == true
    return AsyncThrowingStream { continuation in
      continuation.yield(.token(query ? "Moon composition evidence" : "A normal response"))
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
