import AppKit
import Combine
import LocalAuthentication
import Security
import SwiftUI
import XCTest
@testable import PrimaryAgent

@MainActor
final class ScreenViewTests: XCTestCase {
  func testLiquidGlassSettingsAndAssetsRender() throws {
    for name in ["ForestBackdrop", "TemplateAttachment"] {
      let image = try XCTUnwrap(NSImage(named: name))
      XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
    let credentials = ScreenTestCredentialStore()
    let settings = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport()),
      codexAvailable: { false })
    for destination in SettingsView.SettingsDestination.allCases {
      let view = NSHostingView(rootView: SettingsView(settings: settings, initialDestination: destination))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = view
      defer { window.contentView = nil }
      view.layoutSubtreeIfNeeded()
      XCTAssertEqual(view.fittingSize, NSSize(width: 900, height: 740))
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Glass-Settings-\(destination == .local ? "Local" : "Cloud").png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "Liquid Glass settings · \(destination.rawValue)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testConversationBubblesAndSentAttachmentRender() throws {
    var outgoing = ChatMessage(role: .user, content: "Could you review the notes I attached and suggest a clearer introduction?")
    outgoing.attachments = [MessageAttachment(name: "Project notes.txt", isDirectory: false)]
    let encoded = try JSONEncoder().encode(outgoing)
    XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: encoded).attachments, outgoing.attachments)
    let preview = VStack(alignment: .leading, spacing: 24) {
      LocalMessageView(message: outgoing)
      LocalMessageView(message: ChatMessage(role: .assistant, content: "Start with the purpose of the project, then explain who it helps. Keep the first paragraph focused on the reader.\n\nHere is a more direct opening you can build on."))
      LocalMessageView(message: ChatMessage(role: .user, content: "That feels much clearer. Thank you."))
    }.padding(28).frame(width: 620, height: 390).background(Color(nsColor: .windowBackgroundColor))
    let view = NSHostingView(rootView: preview.environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 390), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.contentView = nil }
    view.frame = NSRect(x: 0, y: 0, width: 620, height: 390)
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Bubbles.png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Chat bubbles and sent attachments"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testRemovingWaitingRowKeepsFollowingButLiveScrollStillReleases() {
    let document = ConversationTestDocument(flipped: true)
    document.frame = NSRect(x: 0, y: 0, width: 400, height: 1600)
    let observer = ConversationScrollObserver.ObserverView()
    observer.frame = document.bounds
    document.addSubview(observer)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    scroll.documentView = document
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    observer.scrollToBottomIfFollowing()
    document.setFrameSize(NSSize(width: 400, height: 1500))
    // Simulate the offset adjustment SwiftUI makes after removing the leaf row.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 1150))
    XCTAssertTrue(observer.followsLatest)
    observer.scrollToBottomIfFollowing()
    XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.maxY, accuracy: 1)
    document.setFrameSize(NSSize(width: 400, height: 1450))
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    observer.scrollToBottomIfFollowing()
    XCTAssertFalse(observer.followsLatest)
    XCTAssertEqual(scroll.contentView.bounds.minY, 1000, accuracy: 1)
  }

  func testStreamRevisionFollowsEvenWithoutObserverFrameChanges() async throws {
    let document = ConversationTestDocument(flipped: true)
    document.frame = NSRect(x: 0, y: 0, width: 400, height: 1600)
    let observer = ConversationScrollObserver.ObserverView()
    observer.frame = document.bounds
    document.addSubview(observer)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    scroll.documentView = document
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    observer.scrollToBottomIfFollowing()
    // Bounds-only growth deliberately does not send the document frame notification.
    document.setBoundsSize(NSSize(width: 400, height: 1900))
    observer.contentChanged("new streamed text")
    let followed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      abs(scroll.contentView.bounds.maxY - document.bounds.maxY) < 2
    }, object: nil)
    await fulfillment(of: [followed], timeout: 2)
    XCTAssertTrue(observer.followsLatest)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 8))
    observer.contentChanged("more streamed text")
    observer.scrollToBottomIfFollowing()
    XCTAssertFalse(observer.followsLatest)
    XCTAssertGreaterThan(document.bounds.maxY - scroll.contentView.bounds.maxY, 2)
  }

  func testConversationScrollPreservesReadingPositionAcrossLayoutAndStreaming() throws {
    for flipped in [true, false] {
      let document = ConversationTestDocument(flipped: flipped)
      document.frame = NSRect(x: 0, y: 0, width: 400, height: 1600)
      let observer = ConversationScrollObserver.ObserverView()
      observer.frame = document.bounds
      document.addSubview(observer)
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
      scroll.documentView = document
      let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = scroll
      defer { window.contentView = nil }
      observer.scrollToBottomIfFollowing()
      XCTAssertTrue(observer.followsLatest)
      let bottom = scroll.contentView.bounds.minY

      // A tiny wheel/keyboard movement cancels a layout correction already queued.
      observer.setFrameSize(NSSize(width: 400, height: 1601))
      scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom + (flipped ? -8 : 8)))
      let readingPosition = scroll.contentView.bounds.minY
      XCTAssertFalse(observer.followsLatest)
      observer.scrollToBottomIfFollowing()
      XCTAssertEqual(scroll.contentView.bounds.minY, readingPosition, accuracy: 0.5)

      document.setFrameSize(NSSize(width: 400, height: 2000))
      observer.setFrameSize(document.bounds.size)
      observer.scrollToBottomIfFollowing()
      XCTAssertFalse(observer.followsLatest)
      XCTAssertEqual(scroll.contentView.bounds.minY, readingPosition, accuracy: 0.5)

      // Returning to the bottom restores following for the next streamed growth.
      let newBottom = flipped ? document.bounds.maxY - scroll.contentView.bounds.height : 0
      scroll.contentView.scroll(to: NSPoint(x: 0, y: newBottom))
      XCTAssertTrue(observer.followsLatest)
      document.setFrameSize(NSSize(width: 400, height: 2200))
      observer.setFrameSize(document.bounds.size)
      observer.scrollToBottomIfFollowing()
      XCTAssertEqual(scroll.contentView.bounds.minY,
                     flipped ? document.bounds.maxY - scroll.contentView.bounds.height : 0, accuracy: 0.5)

      // Trackpad gestures suspend following even before their first offset change.
      NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
      observer.setFrameSize(NSSize(width: 400, height: 2201))
      observer.scrollToBottomIfFollowing()
      XCTAssertFalse(observer.followsLatest)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: flipped ? 100 : 1000))
      NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
      XCTAssertFalse(observer.followsLatest)
      let olderPosition = scroll.contentView.bounds.minY
      observer.scrollToBottomIfFollowing()
      XCTAssertEqual(scroll.contentView.bounds.minY, olderPosition, accuracy: 0.5)
    }
  }

  func testPlusMenuIconsHaveCompactIntrinsicSizesWithoutChangingAssets() throws {
    for name in ["ScreenCapture", "WebSearch"] {
      let source = try XCTUnwrap(NSImage(named: name))
      let originalSize = source.size
      let image = ToolMenuLabel.menuImage(named: name)
      XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
      XCTAssertTrue(image.isTemplate)
      XCTAssertFalse(image === source)
      XCTAssertEqual(source.size, originalSize)
      XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
    let preview = VStack(alignment: .leading, spacing: 10) {
      ToolMenuLabel(title: "Screen", imageName: "ScreenCapture")
      ToolMenuLabel(title: "Web Search", imageName: "WebSearch")
      Divider()
      HStack {
        Text("Hide Inactive Tools")
        Spacer()
        Text("⇧⌘H").foregroundStyle(.secondary)
      }
    }
    .font(.system(size: 13)).padding(12).frame(width: 240)
    .background(Color(nsColor: .windowBackgroundColor))
    let renderer = ImageRenderer(content: preview.environment(\.colorScheme, .dark))
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.cgImage)
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Compact-Tool-Icons.png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Compact tool menu labels"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testHideInactiveToolsReclaimsSpaceAndPreservesActiveToolsAndDrafts() async throws {
    for (searchEnabled, screenEnabled, busy) in [
      (false, false, false), (true, false, false), (false, true, false),
      (true, true, false), (false, false, true),
    ] {
      let state = ToolControlsTestState()
      state.searchEnabled = searchEnabled
      let screen = ScreenComposerCoordinator(captureService: PreviewCapture(), ocrService: PreviewOCR())
      _ = await screen.capture()
      let attachmentID = try XCTUnwrap(screen.attachment?.id)
      screen.isEnabled = screenEnabled
      screen.draft = "Keep this draft"
      let view = NSHostingView(rootView: ToolControlsTestView(state: state, screen: screen, busy: busy))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 50),
                            styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = view
      view.layoutSubtreeIfNeeded()
      await Task.yield()
      let initialWidth = view.fittingSize.width
      NotificationCenter.default.post(name: .hideInactiveToolsRequested, object: nil)
      await Task.yield()
      view.layoutSubtreeIfNeeded()
      XCTAssertEqual(state.searchPresented, searchEnabled || busy)
      XCTAssertEqual(screen.isPresented, screenEnabled || busy)
      XCTAssertEqual(state.searchEnabled, searchEnabled)
      XCTAssertEqual(screen.isEnabled, screenEnabled)
      XCTAssertEqual(screen.draft, "Keep this draft")
      XCTAssertEqual(screen.attachment?.id, attachmentID)
      let removed = busy ? 0 : (searchEnabled ? 0 : 1) + (screenEnabled ? 0 : 1)
      XCTAssertEqual(initialWidth - view.fittingSize.width, Double(removed * 40), accuracy: 0.5)
      window.contentView = nil
    }
  }

  func testSentImagesStaySmallAndPreserveTheirProportions() throws {
    let sizes: [NSSize] = [
      NSSize(width: 1600, height: 800),
      NSSize(width: 800, height: 1600),
      NSSize(width: 1000, height: 1000),
    ]
    let expected: [NSSize] = [
      NSSize(width: 120, height: 60),
      NSSize(width: 48, height: 96),
      NSSize(width: 96, height: 96),
    ]
    var messages: [ChatMessage] = []
    for (index, size) in sizes.enumerated() {
      let source = NSImage(size: size, flipped: false) { bounds in
        NSColor.systemTeal.setFill()
        bounds.fill()
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.15, y: size.height * 0.25,
          width: min(size.width, size.height) * 0.4, height: min(size.width, size.height) * 0.4)).fill()
        return true
      }
      let data = try XCTUnwrap(try ScreenAttachment(image: source).makeMessagePreview())
      let image = try XCTUnwrap(NSImage(data: data))
      let view = NSHostingView(rootView: SentImagePreview(image: image))
      XCTAssertEqual(view.fittingSize.width, expected[index].width, accuracy: 0.5)
      XCTAssertEqual(view.fittingSize.height, expected[index].height, accuracy: 0.5)
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
      XCTAssertLessThanOrEqual(bitmap.pixelsWide, 240)
      XCTAssertLessThanOrEqual(bitmap.pixelsHigh, 192)
      var message = ChatMessage(role: .user, content: ["What is in this image?", "Describe this portrait image.", "And this square image?"][index])
      message.imagePreview = data
      messages.append(message)
    }
    let preview = VStack(alignment: .leading, spacing: 20) {
      ForEach(messages) { message in
        LocalMessageView(message: message)
      }
      LocalMessageView(message: ChatMessage(role: .assistant, content: "Each image shows a yellow circle on a teal background."))
    }
    .padding(24).frame(width: 440).background(Color(nsColor: .windowBackgroundColor))
    let renderer = ImageRenderer(content: preview)
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.cgImage)
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Sent-Image-Previews.png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Sent image thumbnails above message text"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

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
    try await verifyFullPanelScreenSubmission(searchEnabled: false)
  }

  func testFullPanelCombinesScreenAndSearchDuringRapidStreaming() async throws {
    try await verifyFullPanelScreenSubmission(searchEnabled: true)
  }

  func testCombinedCommandsSearchBeforeAutomaticScreenSubmission() async throws {
    for commands in ["/screen /search", "/search /screen", "/SCREEN /SEARCH", "/screen /search /screen /search"] {
      try await verifyFullPanelScreenSubmission(searchEnabled: true, commands: commands)
    }
  }

  func testLongScreenSearchConversationSettlesAtBottom() async throws {
    try await verifyFullPanelScreenSubmission(searchEnabled: true, historyCount: 40)
  }

  private func verifyFullPanelScreenSubmission(searchEnabled: Bool, commands: String? = nil, historyCount: Int = 0) async throws {
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
    let search = PanelSearch()
    let store = ChatSessionStore(applicationSupportDirectory: directory)
    if historyCount > 0 {
      let history = (0..<historyCount).map { index in
        ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
          content: "Earlier message \(index). " + String(repeating: "A longer reply with wrapping text. ", count: 1 + index % 12))
      }
      try store.save([ChatSession(messages: history)])
    }
    let chat = LocalChatViewModel(engine: engine, webSearch: search,
                                 sessionStore: store)
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
      searchSettings: WebSearchSettings(credentials: PresenceOnlyCredentials()))
      .transaction { if historyCount == 0 { $0.disablesAnimations = true } })
    let sizes = PanelSizeStore(defaults: defaults)
    sizes.save(NSSize(width: 752, height: 462))
    let controller = SpotlightPanelController(glassAppearance: appearance, sizeStore: sizes, contentView: view)
    controller.show()
    defer { controller.hide() }
    let prompt = "What is the answer to this piece of code?"
    if let commands {
      view.layoutSubtreeIfNeeded()
      screen.draft = commands + " " + prompt
      // Submit in the same turn, before SwiftUI can run an onChange action.
      try submitComposer(in: view)
    } else {
      _ = await screen.capture()
      screen.draft = (searchEnabled ? "/search " : "") + prompt
      try await renderPanel(view, state: "attached")
      XCTAssertEqual(screen.draft, prompt)
      try submitComposer(in: view)
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
    if searchEnabled {
      let png = try Data(contentsOf: URL(fileURLWithPath: "/tmp/AI-Spotlight-Panel-reply.png"))
      try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Screen-Search.png"))
      let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }
        .max { view.convert($0.bounds, from: $0).midX < view.convert($1.bounds, from: $1).midX })
      let suffix = String(repeating: " More detail.", count: 80)
      let bottom = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        guard let document = scroll.documentView,
              chat.messages.last?.content == "The answer is values.count." + suffix else { return false }
        return document.bounds.height > scroll.contentView.bounds.height
          // The last message ends before the stack's 24-point bottom padding.
          && abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) <= 25
      }, object: nil)
      let burst = expectation(description: "All rapid reply fragments appear")
      let burstToken = chat.$sessions.filter {
        $0.flatMap(\.messages).last?.content == "The answer is values.count." + suffix
      }.prefix(1).sink { _ in burst.fulfill() }
      for _ in 0..<80 { stream.continuation.yield(" More detail.") }
      await fulfillment(of: [burst, bottom], timeout: 5)
      XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0,
                           "Expected a scroll, visible: \(scroll.documentVisibleRect), document: \(String(describing: scroll.documentView?.bounds))")
      burstToken.cancel()
      await Task.yield()
      view.layoutSubtreeIfNeeded()
      if historyCount > 0 {
        let observer = try XCTUnwrap(descendants(view).compactMap { $0 as? ConversationScrollObserver.ObserverView }.first)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 8))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(observer.followsLatest, "Even a small scroll must let the reader leave the bottom")
        let readingPosition = scroll.contentView.bounds.minY
        let extra = String(repeating: " Additional streamed detail.", count: 40)
        let received = expectation(description: "Reply grows while reading history")
        let receivedToken = chat.$sessions.filter { $0.flatMap(\.messages).last?.content.hasSuffix(extra) == true }
          .prefix(1).sink { _ in received.fulfill() }
        stream.continuation.yield(extra)
        await fulfillment(of: [received], timeout: 5)
        receivedToken.cancel()
        view.layoutSubtreeIfNeeded()
        observer.scrollToBottomIfFollowing()
        XCTAssertFalse(observer.followsLatest)
        XCTAssertEqual(scroll.contentView.bounds.minY, readingPosition, accuracy: 2,
                       "Streaming must not pull the reader back to the newest reply")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        view.layoutSubtreeIfNeeded()
        observer.scrollToBottomIfFollowing()
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 2, "The oldest messages remain reachable")
      }
    }
    let done = expectation(description: "Request finished")
    let token = chat.$state.filter { $0 == .idle }.prefix(1).sink { _ in done.fulfill() }
    stream.continuation.finish()
    await fulfillment(of: [done], timeout: 5)
    token.cancel()
    if !searchEnabled { try await renderPanel(view, state: "finished") }
    XCTAssertNil(screen.attachment)
    XCTAssertFalse(chat.isBusy)
    let queries = await search.queries
    XCTAssertEqual(queries, searchEnabled ? ["Swift values.count meaning"] : [])
    XCTAssertEqual(chat.messages.count, historyCount + 2)
    XCTAssertEqual(chat.messages[historyCount].content, prompt)
    XCTAssertEqual(chat.messages.last?.searchSources, searchEnabled ? [PanelSearch.source] : nil)
    XCTAssertEqual(screen.draft, "")
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

    for size in [NSSize(width: 1200, height: 780), NSSize(width: 640, height: 420)] {
      window.setContentSize(size)
      await Task.yield()
      view.layoutSubtreeIfNeeded()
      let field = try composerField(in: view)
      XCTAssertTrue(view.bounds.contains(view.convert(field.bounds, from: field)))
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Glass-\(Int(size.width)).png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "Liquid Glass welcome \(Int(size.width))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    window.setContentSize(NSSize(width: 752, height: 462))

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
      .first { $0.placeholderString == "Ask anything..." })
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func assertPanelControls(_ view: NSView, phase: String) async throws {
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    view.window?.displayIfNeeded()
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
    let history = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first {
      view.convert($0.bounds, from: $0).minX < 30
    })
    let historyFrame = view.convert(history.bounds, from: history)
    XCTAssertFalse(history.isHiddenOrHasHiddenAncestor)
    XCTAssertGreaterThan(historyFrame.width, 180)
    XCTAssertLessThan(historyFrame.width, 270)
    XCTAssertEqual(historyFrame.minY, 12, accuracy: 1, "Inset sidebar moved during \(phase)")
    XCTAssertEqual(historyFrame.height, view.bounds.height - 24, accuracy: 1)
    XCTAssertTrue(view.bounds.contains(historyFrame), "History outside panel during \(phase)")
    XCTAssertGreaterThan(try XCTUnwrap(history.documentView).frame.height, 0)
    XCTAssertTrue(text.contains("auto"), "Composer mode missing during \(phase): \(text)")
  }

  private func renderPanel(_ view: NSView, state: String) async throws {
    let expected = switch state {
    case "attached": ["screen region", "what is the answer"]
    case "loading": ["preparing", "stop", "what is the answer"]
    case "reply": ["the answer is", "streaming", "stop"]
    default: ["the answer is", "local ocr"]
    }
    // Real animations can leave labels temporarily transparent. Wait for the
    // same required pixels instead of assuming one main-actor yield is enough.
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var text = ""
    var png = Data()
    repeat {
      await Task.yield()
      view.layoutSubtreeIfNeeded()
      view.window?.displayIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      text = try await ScreenOCRService().recognize(XCTUnwrap(bitmap.cgImage)).text.lowercased()
    } while !expected.allSatisfy(text.contains) && ContinuousClock.now < deadline
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Panel-\(state).png"))
    let rendered = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    rendered.name = "Screen panel · \(state)"
    rendered.lifetime = .keepAlways
    add(rendered)
    XCTAssertEqual(view.bounds.size, NSSize(width: 752, height: 462))
    if state == "reply" || state == "finished" {
      // OCR can merge the placeholder with adjacent tool icons. Inspect the
      // native field and its visible bounds to verify the actual composer instead.
      let field = try composerField(in: view)
      XCTAssertEqual(field.stringValue, "")
      XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
      XCTAssertTrue(view.bounds.contains(view.convert(field.bounds, from: field)))
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

private actor PanelSearch: WebSearchProvider {
  static let source = WebSearchSource(title: "Code reference", url: URL(string: "https://example.com/code")!)
  private(set) var queries: [String] = []
  func search(_ query: String, maximumTokens: Int) async throws -> [WebSearchResult] {
    queries.append(query)
    return [WebSearchResult(source: Self.source, snippets: ["The count property returns the number of elements."])]
  }
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
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    if request.prompt.hasPrefix("Read the attached screenshot") {
      return AsyncThrowingStream { $0.yield("Swift values.count meaning"); $0.finish() }
    }
    started()
    return response
  }
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

@MainActor
private final class ToolControlsTestState: ObservableObject {
  @Published var searchEnabled = false
  @Published var searchPresented = true
}

private struct ToolControlsTestView: View {
  @ObservedObject var state: ToolControlsTestState
  @ObservedObject var screen: ScreenComposerCoordinator
  let busy: Bool

  var body: some View {
    HStack(spacing: 0) {
      WebSearchControls(isEnabled: $state.searchEnabled, isPresented: $state.searchPresented,
                        isBusy: busy, openSettings: {}, captureScreen: {})
      ScreenToolButton(coordinator: screen, isBusy: busy, capture: {})
    }
    .fixedSize()
    .transaction { $0.disablesAnimations = true }
  }
}

private final class ConversationTestDocument: NSView {
  private let usesFlippedCoordinates: Bool
  init(flipped: Bool) {
    self.usesFlippedCoordinates = flipped
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { usesFlippedCoordinates }
}
