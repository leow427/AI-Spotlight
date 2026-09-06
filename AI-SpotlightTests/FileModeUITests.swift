import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PrimaryAgent

@MainActor
final class FileModeUITests: XCTestCase {
  private var root: URL!
  private var project: URL!
  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    project = root.appendingPathComponent("MyProject")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("Hello".utf8).write(to: project.appendingPathComponent("hello.txt"))
  }
  override func tearDown() async throws { try FileManager.default.removeItem(at: root) }

  func testMenuActivationPresentsPickerAndAllowsFileAndFolderSelection() async throws {
    let panel = FinderWorkspacePicker.panel()
    XCTAssertTrue(panel.canChooseFiles)
    XCTAssertTrue(panel.canChooseDirectories)
    XCTAssertTrue(panel.allowsMultipleSelection)
    let picker = FileTestPicker([project.appendingPathComponent("hello.txt")])
    let files = FileModeCoordinator(picker: picker, journalDirectory: root.appendingPathComponent("Recovery"))
    XCTAssertNil(files.selection)
    XCTAssertEqual(picker.count, 0)
    await files.activate(from: .menu)
    XCTAssertEqual(picker.count, 1)
    XCTAssertEqual(files.selection?.attachments.first?.isDirectory, false)
    picker.urls = [project]
    await files.activate(from: .menu)
    XCTAssertEqual(files.selection?.attachments.count, 1, "The parent folder supersedes the overlapping file grant")
    XCTAssertEqual(files.selection?.attachments.last?.isDirectory, true)
    files.remove(id: try XCTUnwrap(files.selection?.attachments.first?.id))
    XCTAssertNil(files.selection)
  }

  func testPickerCancelPreservesExistingAttachmentAndNeverActivatesOnItsOwn() async throws {
    let picker = FileTestPicker(nil)
    let files = FileModeCoordinator(picker: picker, journalDirectory: root.appendingPathComponent("Recovery"))
    await files.activate(from: .menu)
    XCTAssertNil(files.selection)
    picker.urls = [project]
    await files.activate(from: .menu)
    let selection = files.selection
    picker.urls = nil
    await files.activate(from: .keyboard)
    XCTAssertEqual(files.selection, selection)
  }

  func testShiftOptionFInvokesSamePickerThroughNativePanelWhileTyping() async throws {
    XCTAssertEqual(PanelShortcut.resolve(characters: "F", modifiers: [.option, .shift]), .fileMode)
    XCTAssertNil(PanelShortcut.resolve(characters: "f", modifiers: [.option]))
    XCTAssertNil(PanelShortcut.resolve(characters: "f", modifiers: [.option, .shift, .command]))
    let picker = FileTestPicker([project])
    let files = FileModeCoordinator(picker: picker, journalDirectory: root.appendingPathComponent("Recovery"))
    let chat = LocalChatViewModel(engine: FileTestEngine(), files: files, sessionStore: .init(applicationSupportDirectory: root))
    let screen = ScreenComposerCoordinator()
    screen.draft = "Keep my draft"
    let view = NSHostingView(rootView: AppShellView(glassAppearance: GlassAppearanceSettings(), localChat: chat, screen: screen))
    let controller = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(), contentView: view)
    controller.show()
    defer { controller.hide() }
    await chat.refreshInstalledModel()
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    let window = try XCTUnwrap(view.window)
    let picked = expectation(description: "Finder picker invoked")
    picker.onPick = { picked.fulfill() }
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [.option, .shift], timestamp: 0, windowNumber: window.windowNumber,
      context: nil, characters: "ƒ", charactersIgnoringModifiers: "ƒ", isARepeat: false, keyCode: 3))
    XCTAssertTrue(window.performKeyEquivalent(with: event))
    await fulfillment(of: [picked], timeout: 3)
    await Task.yield()
    XCTAssertEqual(picker.count, 1)
    XCTAssertEqual(files.selection?.attachments.first?.url, try WorkspaceAttachment.canonicalURL(project, isDirectory: true))
    XCTAssertEqual(screen.draft, "Keep my draft")
  }

  func testAttachmentsPersistInConversationAndNewChatHasNoFileMode() async throws {
    let picker = FileTestPicker([project])
    let files = FileModeCoordinator(picker: picker, journalDirectory: root.appendingPathComponent("Recovery"))
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let chat = LocalChatViewModel(engine: FileTestEngine(), files: files, sessionStore: store)
    await files.activate(from: .menu)
    let sessionID = try XCTUnwrap(chat.selectedSessionID)
    XCTAssertEqual(store.load().first?.workspace, files.selection)
    chat.newChat()
    XCTAssertNil(files.selection)
    XCTAssertNil(chat.selectedSession?.workspace)
    chat.selectSession(id: sessionID)
    XCTAssertNotNil(files.selection)
    XCTAssertEqual(picker.count, 1, "Returning to a chat must not silently prompt or access its files")
  }

  func testFileModeAutoUsesLocalAndOrdinaryChatDoesNotEnterAgentLoop() async throws {
    let picker = FileTestPicker([project])
    let files = FileModeCoordinator(picker: picker, journalDirectory: root.appendingPathComponent("Recovery"))
    let inference = FileUITestInference()
    let engine = FileTestEngine()
    let chat = LocalChatViewModel(engine: engine, files: files, fileInference: inference,
      fileCloudAvailability: { XCTFail("Safe writes must not check cloud availability"); return .available(modelID: "unused") },
      sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    await files.activate(from: .menu)
    let finished = expectation(description: "Local file task completed")
    let token = chat.$state.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
    chat.submitFiles("Please edit hello.txt", mode: .auto, cloudProvider: .chatGPT, cloudModelID: "unused")
    XCTAssertEqual(chat.activeRequest?.route.mode, .local)
    await fulfillment(of: [finished], timeout: 3)
    token.cancel()
    let calls = await inference.count
    XCTAssertEqual(calls, 2)
    XCTAssertNil(files.error)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("hello.txt"), encoding: .utf8), "Updated locally")
    let changes = try XCTUnwrap(files.visibleChanges.first)
    XCTAssertEqual(changes.count, 1)
    await files.undo(changes)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("hello.txt"), encoding: .utf8), "Hello")
    chat.newChat()
    let ordinary = expectation(description: "Ordinary chat completed")
    let ordinaryToken = chat.$state.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in ordinary.fulfill() }
    chat.submit("Hello")
    await fulfillment(of: [ordinary], timeout: 3)
    ordinaryToken.cancel()
    let after = await inference.count
    XCTAssertEqual(after, 2)
    XCTAssertNil(files.selection)
    XCTAssertTrue(chat.messages.contains { $0.content == "Normal chat" })
  }

  func testLocalModeEditsThroughProductionGrantAndSupportsUndo() async throws {
    let files = FileModeCoordinator(picker: FileTestPicker([project]), journalDirectory: root.appendingPathComponent("Recovery"))
    let chat = LocalChatViewModel(engine: FileTestEngine(), files: files, fileInference: FileUITestInference(),
      sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    await files.activate(from: .menu)
    let finished = expectation(description: "Local edit completed")
    let token = chat.$state.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
    chat.submitFiles("Update hello.txt", mode: .local, cloudProvider: .chatGPT, cloudModelID: "unused")
    XCTAssertEqual(chat.activeRequest?.route.mode, .local)
    XCTAssertEqual(chat.activeRequest?.route.usesNetwork, false)
    await fulfillment(of: [finished], timeout: 3)
    token.cancel()
    XCTAssertNil(files.error)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("hello.txt"), encoding: .utf8), "Updated locally")
    await files.undo(try XCTUnwrap(files.visibleChanges.first))
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("hello.txt"), encoding: .utf8), "Hello")
  }

  func testProtectedEditOffersCloudDraftWithoutSendingOrChangingFiles() async throws {
    try Data("source before".utf8).write(to: project.appendingPathComponent("code.swift"))
    let files = FileModeCoordinator(picker: FileTestPicker([project]), journalDirectory: root.appendingPathComponent("Recovery"))
    let inference = FileUITestInference(path: "code.swift")
    let chat = LocalChatViewModel(engine: FileTestEngine(), files: files, fileInference: inference,
      fileCloudAvailability: { .available(modelID: "configured-codex") }, sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    await files.activate(from: .menu)
    let finished = expectation(description: "Protected edit paused")
    let token = chat.$state.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
    chat.submitFiles("Update code.swift", mode: .local, cloudProvider: .chatGPT, cloudModelID: "unused")
    await fulfillment(of: [finished], timeout: 3)
    token.cancel()
    XCTAssertEqual(files.protectedWrite, .cloudRequired(paths: ["code.swift"], modelID: "configured-codex"))
    XCTAssertTrue(files.visibleChanges.isEmpty)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("code.swift"), encoding: .utf8), "source before")
    let calls = await inference.count
    XCTAssertEqual(calls, 1, "Do not let the local agent retry or work around a protected edit")
    // The consent action prepares the original request; only the user's subsequent Send submits it.
    let handoff = try XCTUnwrap(files.prepareProtectedCloudDraft())
    XCTAssertEqual(handoff.prompt, "Update code.swift")
    XCTAssertEqual(handoff.modelID, "configured-codex")
    XCTAssertNil(chat.activeRequest)
    XCTAssertFalse(files.isWorking)
    XCTAssertNil(files.protectedWrite)
  }

  func testProtectedLocalFallbackIsVisibleAndUndoableWhenCloudIsUnavailable() async throws {
    try Data("source before".utf8).write(to: project.appendingPathComponent("code.swift"))
    let files = FileModeCoordinator(picker: FileTestPicker([project]), journalDirectory: root.appendingPathComponent("Recovery"))
    let chat = LocalChatViewModel(engine: FileTestEngine(), files: files, fileInference: FileUITestInference(path: "code.swift"),
      fileCloudAvailability: { .unavailable(reason: "No compatible cloud model.") }, sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    await files.activate(from: .menu)
    let finished = expectation(description: "Fallback edit completed")
    let token = chat.$state.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
    chat.submitFiles("Update code.swift", mode: .auto, cloudProvider: .chatGPT, cloudModelID: "unused")
    XCTAssertEqual(chat.activeRequest?.route.usesNetwork, false)
    await fulfillment(of: [finished], timeout: 3)
    token.cancel()
    XCTAssertEqual(files.protectedWrite, .localFallback(paths: ["code.swift"], reason: "No compatible cloud model."))
    XCTAssertNil(files.error)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("code.swift"), encoding: .utf8), "Updated locally")
    await files.undo(try XCTUnwrap(files.visibleChanges.first))
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("code.swift"), encoding: .utf8), "source before")
  }

  func testNativeFileIconAndAttachmentReviewStatesRender() async throws {
    let icon = try XCTUnwrap(NSImage(named: "FileMode"))
    XCTAssertNotNil(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(ToolMenuLabel.menuImage(named: "FileMode").size, NSSize(width: 16, height: 16))
    let picker = FileTestPicker([project])
    let files = FileModeCoordinator(picker: picker, journalDirectory: root.appendingPathComponent("Recovery"))
    await files.activate(from: .menu)
    let tools = try files.begin(access: .readWrite)
    try await tools.workspace.apply([.write(path: "hello.txt", content: "Updated"),
      .create(path: "second.txt", content: "Second"), .create(path: "third.txt", content: "Third")])
    await files.finish(workspace: tools.workspace)
    let preview = VStack(alignment: .leading, spacing: 18) {
      Text("File Mode").font(.title2.weight(.semibold))
      HStack {
        WebSearchControls(isEnabled: .constant(false), isPresented: .constant(false), isBusy: false,
          openSettings: {}, attachFiles: {})
        FileModeToolButton(files: files, isBusy: false, activate: {})
        Text("Ask anything").foregroundStyle(.secondary)
        Spacer()
        Text("Local")
      }
      FileModeAttachmentView(files: files, access: .readWrite, isCloud: false, isBusy: false, useCodex: {})
      FileModeAttachmentView(files: files, access: .readWrite, isCloud: true, isBusy: false, useCodex: {})
      FileChangeSummaryView(files: files, isBusy: false)
    }.padding(24).frame(width: 660).background(Color(nsColor: .windowBackgroundColor))
    let view = NSHostingView(rootView: preview.environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 310),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(x: 0, y: 0, width: 660, height: 310)
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let pinkPixels = (0..<bitmap.pixelsWide).reduce(0) { total, x in
      total + (0..<bitmap.pixelsHigh).filter { y in
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return color.redComponent > 0.6 && color.greenComponent < 0.5 && color.blueComponent > 0.2
      }.count
    }
    XCTAssertGreaterThan(pinkPixels, 100)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-FileMode-Preview.png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "File Mode · Read, Edit and Undo"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertEqual(files.changes.first?.count, 3)
    await files.undo(try XCTUnwrap(files.changes.first))
    XCTAssertTrue(files.changes.isEmpty)
  }
}

@MainActor
private final class FileTestPicker: WorkspacePicking {
  var urls: [URL]?
  var count = 0
  var onPick: (() -> Void)?
  init(_ urls: [URL]?) { self.urls = urls }
  func pick() async -> [URL]? { count += 1; onPick?(); return urls }
}

private actor FileUITestInference: LocalToolInference {
  private(set) var count = 0
  let path: String
  init(path: String = "hello.txt") { self.path = path }
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    count += 1
    XCTAssertTrue(tools.contains { $0.name == "write_file" })
    if count == 1 {
      return AgentInferenceMessage(role: "assistant", content: nil, toolCalls: [AgentToolCall(id: "edit",
        function: .init(name: "write_file", arguments: String(decoding: try JSONEncoder().encode(
          ["path": path, "content": "Updated locally"]), as: UTF8.self)))])
    }
    XCTAssertTrue(messages.contains { $0.role == "tool" && $0.content?.contains("File edited") == true })
    return AgentInferenceMessage(role: "assistant", content: "Updated the file locally. Undo is available.")
  }
}

private actor FileTestEngine: LocalModelEngine {
  let model = LocalModel(id: "test", displayName: "Test local model", fileURL: URL(fileURLWithPath: "/tmp/model.gguf"))
  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { model }
  func installedModels() async -> [LocalModel] { [model] }
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel { self.model }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.yield("Normal chat"); $0.finish() }
  }
  func unload() async {}
}
