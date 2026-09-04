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
