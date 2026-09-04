import AppKit
import Combine
import LocalAuthentication
import Security
import SwiftUI
import XCTest
@testable import PrimaryAgent

@MainActor
final class ScreenViewTests: XCTestCase {
  func testKeychainAvailabilityUsesAttributesWithoutAuthentication() throws {
    let store = KeychainCredentialStore(copyMatching: { query, _ in
      let query = query as NSDictionary
      XCTAssertNil(query[kSecReturnData])
      XCTAssertEqual(query[kSecReturnAttributes] as? Bool, true)
      XCTAssertEqual((query[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed, true)
      return errSecSuccess
    })
    XCTAssertTrue(try store.containsAPIKey(for: .openAI))
    for status in [errSecItemNotFound, errSecInteractionNotAllowed] {
      let unavailable = KeychainCredentialStore(copyMatching: { _, _ in status })
      XCTAssertFalse(try unavailable.containsAPIKey(for: .openAI))
    }
  }

  func testCloudAvailabilityDoesNotReadTheSecretDuringScreenRouting() throws {
    let credentials = PresenceOnlyCredentials()
    let settings = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport()),
      codexAvailable: { false })
    XCTAssertTrue(settings.hasCloudAccess(for: .openAI))
  }

  func testComposerSearchSettingsDoNotReadTheSecret() {
    XCTAssertTrue(WebSearchSettings(credentials: PresenceOnlyCredentials()).hasAPIKey)
  }

  func testFullPanelRetainsContentDuringScreenSubmission() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenPanel-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "ScreenPanel-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
      UserDefaults().removePersistentDomain(forName: suite)
    }
    let stream = AsyncThrowingStream<String, Error>.makeStream()
    let started = expectation(description: "Screen request reaches local text model")
    let model = LocalModel(id: "text", displayName: "Qwen2.5 3B Instruct Q8_0", fileURL: directory.appendingPathComponent("text.gguf"))
    let engine = PanelScreenEngine(model: model, response: stream.stream, started: { started.fulfill() })
    let chat = LocalChatViewModel(engine: engine, sessionStore: ChatSessionStore(applicationSupportDirectory: directory))
    await chat.refreshInstalledModel()
    let screen = ScreenComposerCoordinator(captureService: PreviewCapture(), ocrService: PreviewOCR())
    let credentials = ScreenTestCredentialStore()
    let cloud = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: directory),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false })
    let advisor = LocalModelAdvisor(directory: directory, modelsDirectory: directory, defaults: defaults, trust: nil)
    await advisor.start(installedModels: [model])
    let appearance = GlassAppearanceSettings(defaults: defaults)
    let view = NSHostingView(rootView: AppShellView(glassAppearance: appearance, cloudSettings: cloud,
      localChat: chat, screen: screen, modelAdvisor: advisor,
      searchSettings: WebSearchSettings(credentials: PanelSearchCredentials()))
      .transaction { $0.disablesAnimations = true })
    let sizes = PanelSizeStore(defaults: defaults)
    sizes.save(NSSize(width: 752, height: 462))
    let controller = SpotlightPanelController(glassAppearance: appearance, sizeStore: sizes, contentView: view)
    controller.show()
    defer { controller.hide() }
    _ = await screen.capture()
    screen.draft = "What is the answer to this piece of code?"
    let attachment = try XCTUnwrap(screen.attachment)
    try await renderPanel(view, state: "attached")
    screen.updateDecision(.text(model.screenModel))
    chat.submitScreen(screen.draft, attachment: attachment, decision: .text(model.screenModel), selectedMode: .auto,
      cloudUploadAllowed: { false }) {
        screen.draft = ""
        screen.removeAttachment()
      }
    await fulfillment(of: [started], timeout: 5)
    try await renderPanel(view, state: "loading")
    let reply = expectation(description: "First reply appears")
    let replyToken = chat.$sessions.filter { $0.flatMap(\.messages).contains { $0.content == "The answer is values.count." } }
      .prefix(1).sink { _ in reply.fulfill() }
    stream.continuation.yield("The answer is values.count.")
    await fulfillment(of: [reply], timeout: 5)
    replyToken.cancel()
    try await renderPanel(view, state: "reply")
    let done = expectation(description: "Request finished")
    let token = chat.$state.filter { $0 == .idle }.prefix(1).sink { _ in done.fulfill() }
    stream.continuation.finish()
    await fulfillment(of: [done], timeout: 5)
    token.cancel()
    try await renderPanel(view, state: "finished")
    XCTAssertNil(screen.attachment)
    XCTAssertFalse(chat.isBusy)
  }

  func testRepeatedScreenSubmissionsKeepFullPanelInsideWindow() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RepeatedScreenPanel-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "RepeatedScreenPanel-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
      UserDefaults().removePersistentDomain(forName: suite)
    }
    let model = LocalModel(id: "text", displayName: "Text", fileURL: directory.appendingPathComponent("text.gguf"))
    let engine = RepeatedPanelEngine(model: model)
    let store = ChatSessionStore(applicationSupportDirectory: directory)
    let chat = LocalChatViewModel(engine: engine, sessionStore: store)
    await chat.refreshInstalledModel()
    chat.newChat()
    let session = chat.selectedSessionID
    let screen = ScreenComposerCoordinator(captureService: PreviewCapture(), ocrService: PreviewOCR())
    let credentials = ScreenTestCredentialStore()
    let cloud = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: directory),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false })
    let advisor = LocalModelAdvisor(directory: directory, modelsDirectory: directory, defaults: defaults, trust: nil)
    await advisor.start(installedModels: [model])
    let appearance = GlassAppearanceSettings(defaults: defaults)
    let view = NSHostingView(rootView: AppShellView(glassAppearance: appearance, cloudSettings: cloud,
      localChat: chat, screen: screen, modelAdvisor: advisor,
      searchSettings: WebSearchSettings(credentials: PanelSearchCredentials())))
    let sizes = PanelSizeStore(defaults: defaults)
    sizes.save(NSSize(width: 752, height: 462))
    let controller = SpotlightPanelController(glassAppearance: appearance, sizeStore: sizes, contentView: view)
    controller.show()
    defer { controller.hide() }
    let window = try XCTUnwrap(view.window)

    // The layout failure is also reachable on a first blocked request; it
    // depends on the detail's measurement, not a global submission counter.
    screen.draft = "Describe the colors in this diagram."
    _ = await screen.capture()
    try await assertPanelControls(view, phase: "fresh attachment")
    try submitComposer(in: view)
    try await assertPanelControls(view, phase: "first blocked request")
    XCTAssertNotNil(screen.error)
    XCTAssertTrue(chat.messages.isEmpty)
    XCTAssertTrue(engine.requests.isEmpty)
    screen.removeAttachment()

    for cycle in 1...2 {
      screen.draft = "Explain the code in capture \(cycle)."
      if cycle == 1 {
        _ = await screen.capture()
        let original = screen.attachment?.id
        _ = await screen.capture() // Two captures without two submissions.
        XCTAssertNotEqual(screen.attachment?.id, original)
        XCTAssertTrue(engine.requests.isEmpty)
      } else {
        screen.draft = "/screen " + screen.draft
      }
      try await assertPanelControls(view, phase: "before request \(cycle)")
      let completed = expectation(description: "Request \(cycle) completed")
      let token = chat.$state.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in completed.fulfill() }
      try submitComposer(in: view)
      await fulfillment(of: [completed], timeout: 5)
      token.cancel()
      try await assertPanelControls(view, phase: "submission \(cycle)")
      XCTAssertEqual(chat.selectedSessionID, session)
      XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, cycle)
      XCTAssertEqual(engine.requests.count, cycle)
      XCTAssertNil(screen.attachment)
      XCTAssertEqual(screen.draft, "")
      XCTAssertFalse(screen.isEnabled)
      XCTAssertFalse(screen.isBusy)
      XCTAssertNil(chat.activeRequest)
      XCTAssertEqual(chat.state, .idle)
      XCTAssertFalse(chat.isBusy)
      XCTAssertTrue(controller.isVisible)
      XCTAssertTrue(window.isKeyWindow)
      XCTAssertNotNil(try composerField(in: view).currentEditor(), "The completed request must return keyboard focus to the composer")
      XCTAssertFalse(window.ignoresMouseEvents)
    }
    XCTAssertEqual(store.load().first?.messages.filter { $0.role == .user }.map(\.content),
      ["Explain the code in capture 1.", "Explain the code in capture 2."])

    // A blocked vision route adds a wrapped error without starting a producer.
    // This was the exact second-send reflow observed in the signed app.
    _ = await screen.capture()
    screen.draft = "Describe the image."
    screen.error = "Visual analysis requires a local vision model or screenshot-upload permission in Screen settings."
    try await assertPanelControls(view, phase: "blocked vision")
    XCTAssertEqual(engine.requests.count, 2)
    XCTAssertNotNil(screen.attachment)
    screen.removeAttachment()
    try await assertPanelControls(view, phase: "removed attachment")
  }

  private func submitComposer(in view: NSView) throws {
    let window = try XCTUnwrap(view.window)
    XCTAssertTrue(window.makeFirstResponder(try composerField(in: view)))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
  }

  private func composerField(in view: NSView) throws -> NSTextField {
    try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }
      .first { $0.placeholderString == "Ask anything" })
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func assertPanelControls(_ view: NSView, phase: String) async throws {
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    view.window?.displayIfNeeded()
    let split = try XCTUnwrap(descendants(view).compactMap { $0 as? NSSplitView }.first)
    let splitFrame = view.convert(split.bounds, from: split)
    XCTAssertEqual(splitFrame.minY, 0, accuracy: 1, "Split offset during \(phase): \(splitFrame)")
    XCTAssertEqual(splitFrame.height, view.bounds.height, accuracy: 1, "Split overflow during \(phase): \(splitFrame)")
    let field = try composerField(in: view)
    let fieldFrame = view.convert(field.bounds, from: field)
    XCTAssertTrue(view.bounds.contains(fieldFrame), "Composer outside panel during \(phase): \(fieldFrame)")
    XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
    XCTAssertTrue(field.isEnabled)
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let rendered = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    rendered.name = "Repeated Screen · \(phase)"
    rendered.lifetime = .keepAlways
    add(rendered)
    let text = try await ScreenOCRService().recognize(try XCTUnwrap(bitmap.cgImage)).text.lowercased()
    // Native glass renders on a separate surface from cacheDisplay. Verify
    // the actual sidebar, its scroll content, and its position in the panel.
    let sidebar = try XCTUnwrap(split.arrangedSubviews.min { $0.frame.width < $1.frame.width })
    XCTAssertFalse(split.isSubviewCollapsed(sidebar))
    XCTAssertFalse(sidebar.isHiddenOrHasHiddenAncestor)
    XCTAssertGreaterThan(sidebar.frame.width, 180)
    XCTAssertLessThan(sidebar.frame.width, 270)
    XCTAssertTrue(view.bounds.contains(view.convert(sidebar.bounds, from: sidebar)),
      "History sidebar outside panel during \(phase)")
    let history = try XCTUnwrap(descendants(sidebar).compactMap { $0 as? NSScrollView }.first)
    XCTAssertGreaterThan(try XCTUnwrap(history.documentView).frame.height, 0)
    XCTAssertTrue(text.contains("auto"), "Composer mode missing during \(phase): \(text)")
  }

  private func renderPanel(_ view: NSView, state: String) async throws {
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    view.window?.displayIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Panel-\(state).png"))
    let rendered = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    rendered.name = "Screen panel · \(state)"
    rendered.lifetime = .keepAlways
    add(rendered)
    XCTAssertEqual(view.bounds.size, NSSize(width: 752, height: 462))
    let pixels = try XCTUnwrap(bitmap.cgImage)
    let text = try await ScreenOCRService().recognize(pixels).text.lowercased()
    let expected = switch state {
    case "attached": ["screen region", "what is the answer"]
    case "loading": ["preparing", "stop", "what is the answer"]
    case "reply": ["the answer is", "streaming", "stop", "ask anything"]
    default: ["the answer is", "local ocr", "ask anything"]
    }
    for phrase in expected {
      XCTAssertTrue(text.contains(phrase), "Visible panel content missing during \(state): \(phrase)")
    }
  }

  func testScreenIconSlotAndNativeComposerStates() async throws {
    let icon = try XCTUnwrap(NSImage(named: "ScreenCapture"))
    let pixels = try XCTUnwrap(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let bitmapIcon = NSBitmapImageRep(cgImage: pixels)
    let visiblePixels = (0..<bitmapIcon.pixelsWide).reduce(0) { count, x in
      count + (0..<bitmapIcon.pixelsHigh).filter { y in (bitmapIcon.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }.count
    }
    XCTAssertGreaterThan(visiblePixels, 100, "A loaded but blank SVG must fail rendering verification")
    let hidden = ScreenComposerCoordinator()
    let off = ScreenComposerCoordinator()
    off.isPresented = true
    let on = ScreenComposerCoordinator(captureService: PreviewCapture(), ocrService: PreviewOCR())
    _ = await on.capture()
    let hiddenView = NSHostingView(rootView: ScreenToolButton(coordinator: hidden, isBusy: false, capture: {}))
    let offView = NSHostingView(rootView: ScreenToolButton(coordinator: off, isBusy: false, capture: {}))
    XCTAssertEqual(offView.fittingSize.width - hiddenView.fittingSize.width, 40, accuracy: 0.5)
    XCTAssertEqual(offView.fittingSize.height, hiddenView.fittingSize.height)
    let attachment = try XCTUnwrap(on.attachment)
    let preview = VStack(alignment: .leading, spacing: 16) {
      Text("Screen").font(.title2.weight(.semibold))
      ForEach(Array([hidden, off, on].enumerated()), id: \.offset) { index, coordinator in
        Text(["Before adding Screen", "Screen off", "Screen on"][index]).font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 10) {
          HStack(spacing: 0) {
            WebSearchControls(isEnabled: .constant(false), isPresented: .constant(false), isBusy: false, openSettings: {}, captureScreen: {})
            ScreenToolButton(coordinator: coordinator, isBusy: false, capture: {})
          }
          Text("Ask anything").foregroundStyle(.secondary)
          Spacer()
          Label("Auto", systemImage: "sparkles")
        }
        .padding(14)
        .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
      }
      Text("Screenshot attached · ready for a question").font(.caption).foregroundStyle(.secondary)
      ScreenAttachmentView(attachment: attachment, isEnabled: true, isBusy: false, remove: {}, retake: {})
    }
    .padding(24).frame(width: 700).background(Color(nsColor: .windowBackgroundColor))
    let view = NSHostingView(rootView: preview)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 480)
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Screen-Preview.png"))
    let rendered = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    rendered.name = "Screen composer states"
    rendered.lifetime = .keepAlways
    add(rendered)
  }
}

private struct PresenceOnlyCredentials: CloudCredentialStore, WebSearchCredentialStore {
  func containsAPIKey(for provider: CloudProviderID) -> Bool { true }
  func containsAPIKey() -> Bool { true }
  func apiKey(for provider: CloudProviderID) -> String? { apiKey() }
  func apiKey() -> String? {
    XCTFail("Checking availability must not decrypt a secret or open a Keychain prompt")
    return nil
  }
  func setAPIKey(_ value: String, for provider: CloudProviderID) {}
  func removeAPIKey(for provider: CloudProviderID) {}
  func setAPIKey(_ value: String) {}
  func removeAPIKey() {}
}

private struct PanelSearchCredentials: WebSearchCredentialStore {
  func apiKey() -> String? { nil }
  func setAPIKey(_ value: String) {}
  func removeAPIKey() {}
}

private actor PanelScreenEngine: LocalModelEngine {
  let model: LocalModel
  nonisolated let response: AsyncThrowingStream<String, Error>
  nonisolated let started: @Sendable () -> Void
  init(model: LocalModel, response: AsyncThrowingStream<String, Error>, started: @escaping @Sendable () -> Void) {
    self.model = model; self.response = response; self.started = started
  }
  func installedModel() -> LocalModel? { model }
  func installedModels() -> [LocalModel] { [model] }
  func install(_ model: LocalModel) {}
  func selectModel(id: String) {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) -> LocalModel { self.model }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> { started(); return response }
  func unload() {}
}

@MainActor
private struct PreviewCapture: ScreenCapturing {
  func capture() async throws -> NSImage? {
    NSImage(size: NSSize(width: 600, height: 200), flipped: false) { rect in
      NSColor(white: 0.12, alpha: 1).setFill(); rect.fill()
      ("let answer = values.count\nprint(answer)" as NSString).draw(at: NSPoint(x: 20, y: 60), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular), .foregroundColor: NSColor.systemGreen])
      return true
    }
  }
}

private struct PreviewOCR: ScreenOCRReading {
  func recognize(_ image: CGImage) async throws -> ScreenOCRResult {
    ScreenOCRResult(text: "let answer = values.count\nprint(answer)\n// explain this code", confidence: 0.95)
  }
}

private final class RepeatedPanelEngine: LocalModelEngine, @unchecked Sendable {
  let model: LocalModel
  private let lock = NSLock()
  private var captured: [LocalModelRequest] = []
  var requests: [LocalModelRequest] { lock.withLock { captured } }
  init(model: LocalModel) { self.model = model }
  func installedModel() async -> LocalModel? { model }
  func installedModels() async -> [LocalModel] { [model] }
  func install(_ model: LocalModel) async throws {}
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel { self.model }
  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    lock.withLock { captured.append(request) }
    return AsyncThrowingStream { $0.yield("The answer is values.count."); $0.finish() }
  }
  func unload() async {}
}
