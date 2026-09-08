import AppKit
import Combine
import SwiftUI
@preconcurrency import ApplicationServices
import UniformTypeIdentifiers
import WebKit

/// Follow new layout only while the reader remains at the end of the chat.
struct ConversationScrollObserver: NSViewRepresentable {
  var contentRevision = ""
  func makeNSView(context: Context) -> ObserverView { ObserverView() }
  func updateNSView(_ view: ObserverView, context: Context) { view.contentChanged(contentRevision) }

  final class ObserverView: NSView {
    private var contentRevision = ""
    func contentChanged(_ revision: String) {
      guard revision != contentRevision else { return }
      contentRevision = revision
      scheduleScroll()
    }
    private var pendingScroll: DispatchWorkItem?
    private weak var observedScroll: NSScrollView?
    private var previousClipBounds = NSRect.zero
    private var previousDocumentSize = NSSize.zero
    private var isAdjustingScroll = false
    private var isSettlingDocumentLayout = false
    private var isLiveScrolling = false
    private var hasPositionedInitially = false
    private(set) var followsLatest = true

    override func setFrameSize(_ newSize: NSSize) {
      let changed = frame.size != newSize
      super.setFrameSize(newSize)
      if changed { scheduleScroll() }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      disconnect()
      if window != nil {
        connect()
        scheduleScroll()
      }
    }

    private func connect() {
      guard let scroll = enclosingScrollView, observedScroll !== scroll else { return }
      observedScroll = scroll
      rememberGeometry()
      scroll.contentView.postsBoundsChangedNotifications = true
      let center = NotificationCenter.default
      if let document = scroll.documentView {
        document.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(documentLayoutChanged),
                           name: NSView.frameDidChangeNotification, object: document)
      }
      center.addObserver(self, selector: #selector(boundsChanged),
                         name: NSView.boundsDidChangeNotification, object: scroll.contentView)
      center.addObserver(self, selector: #selector(beginScrolling),
                         name: NSScrollView.willStartLiveScrollNotification, object: scroll)
      center.addObserver(self, selector: #selector(endScrolling),
                         name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    private func disconnect() {
      pendingScroll?.cancel()
      pendingScroll = nil
      NotificationCenter.default.removeObserver(self)
      observedScroll = nil
      isLiveScrolling = false
    }

    private var isAtBottom: Bool {
      guard let scroll = observedScroll, let document = scroll.documentView else { return false }
      let visible = scroll.contentView.bounds
      let distance = document.isFlipped
        ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
      return distance <= 2
    }

    private func rememberGeometry() {
      previousClipBounds = observedScroll?.contentView.bounds ?? .zero
      previousDocumentSize = observedScroll?.documentView?.bounds.size ?? .zero
    }

    @objc private func documentLayoutChanged() {
      isSettlingDocumentLayout = followsLatest
      rememberGeometry()
      scheduleScroll()
    }

    @objc private func beginScrolling() {
      isLiveScrolling = true
      followsLatest = false
      pendingScroll?.cancel()
      pendingScroll = nil
    }

    @objc private func endScrolling() {
      isLiveScrolling = false
      followsLatest = isAtBottom
      rememberGeometry()
      if followsLatest { scheduleScroll() }
    }

    @objc private func boundsChanged() {
      guard let scroll = observedScroll else { return }
      defer { rememberGeometry() }
      guard !isAdjustingScroll, hasPositionedInitially else { return }
      // Removing the waiting row can trigger a native offset correction after the
      // document notification. That correction is layout, not reader navigation.
      let event = NSApp.currentEvent
      let input = event?.type
      let recentInput = event.map { ProcessInfo.processInfo.systemUptime - $0.timestamp < 0.2 } ?? false
      let navigationKey = input == .keyDown && [115, 116, 119, 121, 125, 126].contains(Int(event?.keyCode ?? 0))
      let userNavigation = recentInput && (input == .scrollWheel || navigationKey || input == .leftMouseDragged || input == .leftMouseDown)
      if isSettlingDocumentLayout && !isLiveScrolling && !userNavigation { return }
      // Resizing/streaming changes geometry too. Only an offset change at the
      // same size is navigation; live gestures suspend following before layout.
      let bounds = scroll.contentView.bounds
      if isLiveScrolling || (bounds.origin != previousClipBounds.origin
          && bounds.size == previousClipBounds.size
          && scroll.documentView?.bounds.size == previousDocumentSize) {
        followsLatest = !isLiveScrolling && isAtBottom
        if !followsLatest { pendingScroll?.cancel(); pendingScroll = nil }
      }
    }

    private func scheduleScroll() {
      guard followsLatest, !isLiveScrolling, pendingScroll == nil else { return }
      let work = DispatchWorkItem { [weak self] in self?.scrollToBottomIfFollowing() }
      pendingScroll = work
      // Coalesce repeated lazy-row measurements; recheck reader intent at execution.
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30), execute: work)
    }

    func scrollToBottomIfFollowing() {
      pendingScroll?.cancel()
      pendingScroll = nil
      connect()
      guard followsLatest, !isLiveScrolling, window != nil,
            let scroll = observedScroll, let document = scroll.documentView else { return }
      let clip = scroll.contentView
      let bottom = document.isFlipped
        ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
        : document.bounds.minY
      isAdjustingScroll = true
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom))
      scroll.reflectScrolledClipView(clip)
      isAdjustingScroll = false
      hasPositionedInitially = true
      isSettlingDocumentLayout = false
      rememberGeometry()
    }
  }
}

/// Tokens from Figma's Liquid Glass alternative (16:122).
enum NatureGlass {
  static let accent = Color("SpotlightAccent")
  static let canvas = Color(red: 11/255, green: 18/255, blue: 19/255)
  static let primary = Color(red: 242/255, green: 245/255, blue: 242/255)
  static let secondary = Color(red: 173/255, green: 184/255, blue: 178/255)
  static let edge = LinearGradient(colors: [.white.opacity(0.4), accent.opacity(0.12), .white.opacity(0.22)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct ForestBackdrop: View {
  var body: some View {
    GeometryReader { geometry in
      Image("ForestBackdrop")
        .resizable()
        .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .background(NatureGlass.canvas)
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

/// One optical surface per container; controls inside it use simple fills.
struct NatureGlassSurface: ViewModifier {
  var radius: CGFloat = 24
  var navigation = false
  var enabled = true
  var clarity = 0.22
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content.background {
      let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
      if reduceTransparency || !enabled {
        shape.fill(NatureGlass.canvas)
      } else {
        shape.fill(Color(red: 35/255, green: 54/255, blue: 44/255).opacity(navigation ? 0.38 : 0.09))
          .glassEffect(.regular.tint(NatureGlass.accent.opacity(navigation ? 0.06 : 0.025)), in: shape)
          .opacity(1 - clarity)
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(NatureGlass.edge, lineWidth: 0.75)
        .allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
  }
}

extension View {
  func natureSurface(radius: CGFloat = 24, navigation: Bool = false) -> some View {
    modifier(NatureGlassSurface(radius: radius, navigation: navigation))
  }
  func naturePresentation() -> some View {
    background { ForestBackdrop().ignoresSafeArea() }
      .tint(NatureGlass.accent)
      .preferredColorScheme(.dark)
  }
}

private struct NatureButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(isEnabled ? 1 : 0.45)
      .background(NatureGlass.accent.opacity(isEnabled && isHovered ? 0.09 : 0),
                  in: RoundedRectangle(cornerRadius: 9))
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
      .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
      .onHover { isHovered = $0 }
  }
}

struct AppShellView: View {
  @ObservedObject private var selectionContext = SelectionContextService.shared
  @State private var replacementMessage: ChatMessage?
  @State private var replacementText = ""
  @State private var expandedActivities: Set<UUID> = []
  @ObservedObject var glassAppearance: GlassAppearanceSettings
  @ObservedObject private var cloudSettings: CloudSettingsModel
  @StateObject private var localChat: LocalChatViewModel
  @ObservedObject private var modelAdvisor: LocalModelAdvisor
  @ObservedObject private var files: FileModeCoordinator
  @State private var isFileCloudConsentPresented = false
  @StateObject private var screen: ScreenComposerCoordinator
  @ObservedObject private var screenSettings = ScreenSettings.shared
  @ObservedObject private var connectivity = ScreenConnectivity.shared
  @State private var isScreenPermissionPresented = false
  private var draft: String {
    get { screen.draft }
    nonmutating set { screen.draft = newValue }
  }
  @State private var isSearchEnabled = false
  @State private var isSearchPresented = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject private var searchSettings: WebSearchSettings
  @State private var isModelImporterPresented = false
  @State private var isModePalettePresented = false
  @State private var isHelpPresented = false
  @State private var isSidebarVisible = false
  @State private var selectedMode = ChatMode.auto
  @State private var isComposerFocused = false

  init(
    glassAppearance: GlassAppearanceSettings,
    localEngine: (any LocalModelEngine)? = nil,
    cloudSettings: CloudSettingsModel = .shared,
    cloudProviders: CloudProviderRegistry = .live,
    localChat: LocalChatViewModel? = nil,
    screen: ScreenComposerCoordinator = ScreenComposerCoordinator(),
    modelAdvisor: LocalModelAdvisor = .shared,
    searchSettings: WebSearchSettings = .shared
  ) {
    self.glassAppearance = glassAppearance
    self.cloudSettings = cloudSettings
    self.modelAdvisor = modelAdvisor
    self.searchSettings = searchSettings
    _screen = StateObject(wrappedValue: screen)
    let chat = localChat ?? localEngine.map { LocalChatViewModel(engine: $0, cloudProviders: cloudProviders) } ?? .shared
    _localChat = StateObject(wrappedValue: chat)
    self.files = chat.files
  }

  private var shellLayout: some View {
    ZStack {
      welcomeBackground
        .ignoresSafeArea()

      GeometryReader { geometry in
        HStack(spacing: 0) {
          if isSidebarVisible {
            sidebar(compact: geometry.size.width < 900)
              .frame(width: min(288, max(200, geometry.size.width * 0.27)))
          }
          // Bound detail measurement so wrapped notices cannot push the
          // composer outside a small panel.
          GeometryReader { _ in
            VStack(spacing: 0) {
              if !isSidebarVisible { hiddenSidebarNavigation }
              conversation

              VStack(alignment: .trailing, spacing: 8) {
                routeStatus
                if let notice = localChat.contextNotice {
                  Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let decision = localChat.screenRouteDecision {
                  Text(decision.status + (decision.sendsImage ? "" : " · Image not sent"))
                    .font(.caption).foregroundStyle(.secondary)
                }
                if isSearchEnabled || (searchSettings.canSearchAutomatically && files.selection == nil) {
                  HStack(spacing: 6) {
                    Text(searchSettings.hasAPIKey
                      ? (isSearchEnabled ? "Web Search · Queries sent to Brave may include attached context."
                        : "Auto search · Current topics may use Brave, including relevant attached context.")
                      : "Add a Brave Search API key to search the web.")
                    if !searchSettings.hasAPIKey {
                      Button("Settings", action: openSettings).buttonStyle(.plain)
                    }
                  }
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }

                if localChat.isTemporaryChat {
                  Text("Temporary chat · Not saved to history").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(localChat.attachedContexts) { context in
                  SelectionContextCard(context: context, isBusy: localChat.isBusy || selectionContext.isWorking) {
                    localChat.removeContext(id: context.id)
                  }
                }
                if let notice = selectionContext.notice, localChat.isTemporaryChat {
                  Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                if let attachment = screen.attachment, localChat.pendingUserMessage == nil {
                  ScreenAttachmentView(attachment: attachment, isEnabled: screen.isEnabled,
                                       isBusy: localChat.isBusy || screen.isBusy,
                                       remove: screen.removeAttachment, retake: captureScreen)
                }
                if let error = screen.error {
                  Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if files.selection != nil || files.error != nil || files.protectedWrite != nil {
                  FileModeAttachmentView(files: files, access: fileAccess, isCloud: selectedMode == .cloud, isBusy: localChat.isBusy,
                    useCodex: { isFileCloudConsentPresented = true })
                }
                FileChangeSummaryView(files: files, isBusy: localChat.isBusy)
                composer(compact: geometry.size.width < 900)
              }
              .padding(.horizontal, 24)
              .padding(.bottom, 32)
              .padding(.top, 8)
            }
          }
        }
      }

      if isModePalettePresented {
        modePalette
      }
    }
    .tint(NatureGlass.accent)
    .preferredColorScheme(.dark)
    .frame(minWidth: 640, minHeight: 420)
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(NatureGlass.edge, lineWidth: 0.75)
    }
  }

  private var observedShell: some View {
    shellLayout
    .onReceive(NotificationCenter.default.publisher(for: .sidebarToggleRequested)) { _ in
      isSidebarVisible.toggle()
    }
    .onReceive(NotificationCenter.default.publisher(for: .fileModeRequested)) { _ in
      activateFileMode(from: .keyboard)
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectionContextRequested)) { notification in
      screen.clearDraft()
      isSearchEnabled = false
      isSearchPresented = false
      isModePalettePresented = false
      isHelpPresented = false
      replacementMessage = nil
      localChat.startTemporaryChat(context: notification.object as? ConversationContext)
      isComposerFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in
      screen.clearDraft()
      isSearchEnabled = false
      isSearchPresented = false
      localChat.newChat()
      isModePalettePresented = false
      isComposerFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .modePaletteRequested)) { _ in
      isModePalettePresented.toggle()
    }
    .onReceive(NotificationCenter.default.publisher(for: .settingsRequested)) { _ in
      isModePalettePresented = false
    }
    .onReceive(NotificationCenter.default.publisher(for: .panelPresented)) { _ in
      localChat.applicationBecameActive()
      Task { await modelAdvisor.refreshCatalog() }
      isComposerFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .panelHidden)) { _ in
      localChat.applicationBecameInactive()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      localChat.applicationBecameActive()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      localChat.applicationBecameInactive()
    }
    .onReceive(NotificationCenter.default.publisher(for: .stopStreamingRequested)) { _ in
      localChat.stopStreaming()
    }
    .onReceive(NotificationCenter.default.publisher(for: .recentChatCycleRequested)) { _ in
      localChat.cycleRecentChat()
    }
  }

  var body: some View {
    observedShell
    .sheet(isPresented: $modelAdvisor.isOnboardingPresented, onDismiss: { modelAdvisor.dismissOnboarding() }) {
      LocalModelOnboardingView(advisor: modelAdvisor, chat: localChat)
    }
    .modifier(FileModeDialogs(files: files, isCloudConsentPresented: $isFileCloudConsentPresented,
      isBusy: localChat.isBusy, useCodex: {
        cloudSettings.preferredProvider = .chatGPT
        selectedMode = .cloud
        if let handoff = files.prepareProtectedCloudDraft() {
          cloudSettings.preferredModelID = handoff.modelID
          if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = handoff.prompt }
        }
      }))
    .alert("Allow screenshot uploads?", isPresented: $isScreenPermissionPresented) {
      Button("Allow & Send") {
        screenSettings.answerCloudPermission(allow: true)
        submitDraft()
      }
      Button("Keep Screenshots Local", role: .cancel) {
        screenSettings.answerCloudPermission(allow: false)
        screen.error = "Screenshot kept on this Mac. Use a local vision model, or enable uploads in Screen settings."
      }
    } message: { Text(ScreenSettings.permissionExplanation) }
    .onChange(of: localChat.isBusy) { _, busy in
      // A disabled TextField cannot take focus at first-token acceptance.
      // Restore its editor only after the owning request has finished.
      isComposerFocused = !busy
    }
    .onChange(of: localChat.selectedSessionID) { _, _ in
      if localChat.activeRequest == nil { screen.removeAttachment() }
    }
    .onChange(of: screenSettings.allowCloudScreenshots) { _, allowed in
      if !allowed, localChat.screenRouteDecision?.sendsImage == true, localChat.activeRequest?.route.mode == .cloud {
        localChat.stopStreaming()
      }
    }
    .sheet(item: $replacementMessage) { _ in
      VStack(alignment: .leading, spacing: 16) {
        Text("Replace Selection").font(.headline)
        Text("Review or edit the text that will replace the original selection.").font(.caption)
        TextEditor(text: $replacementText).font(.body).scrollContentBackground(.hidden)
        HStack {
          Button("Cancel") { replacementMessage = nil }
          Spacer()
          Button("Replace Selection") {
            guard let contextID = localChat.attachedContexts.first?.id else { return }
            replacementMessage = nil
            let text = replacementText
            Task { _ = await selectionContext.replace(with: text, contextID: contextID) }
          }.buttonStyle(.borderedProminent)
        }
      }.padding(24).frame(width: 520, height: 360).naturePresentation()
    }
    .sheet(isPresented: $isHelpPresented) {
      KeyboardShortcutsHelpView()
    }
    .fileImporter(
      isPresented: $isModelImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result, let url = urls.first {
        localChat.installModel(from: url)
        selectedMode = .local
      }
    }
    .task {
      await localChat.refreshInstalledModel()
      await modelAdvisor.start(installedModels: localChat.installedModels)
    }
    .onChange(of: draft) { _, value in
      guard ComposerCommands(value).search else { return }
      isSearchPresented = true
      isSearchEnabled = true
    }
    .onChange(of: isSearchPresented) { _, _ in
      isComposerFocused = true
    }
    .onChange(of: selectedMode, initial: true) { _, mode in
      localChat.clearAutoRouteDecision()
      guard mode == .cloud || mode == .auto else { return }
      Task {
        if cloudSettings.preferredProvider == .chatGPT {
          await cloudSettings.refreshChatGPTAccount()
        }
        if cloudSettings.hasCloudAccess(for: cloudSettings.preferredProvider) {
          await cloudSettings.discoverModels()
        }
      }
    }
  }

  private var welcomeBackground: some View { ForestBackdrop() }

  private var hiddenSidebarNavigation: some View {
    HStack(spacing: 12) {
      Button { isSidebarVisible = true } label: { Image(systemName: "sidebar.left") }
        .accessibilityLabel("Show chat history").help("Show chat history · double-tap Control")
      Button { isHelpPresented = true } label: { Label("Help", systemImage: "questionmark.circle") }
      Spacer()
      Button(action: openSettings) { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
      Button { NotificationCenter.default.post(name: .newChatRequested, object: nil) } label: {
        Image(systemName: "square.and.pencil")
      }.accessibilityLabel("New chat")
    }
    .font(.system(size: 13))
    .buttonStyle(.borderless)
    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
  }

  private func sidebar(compact: Bool) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: compact ? 4 : 12) {
          Image("SpotlightLogo").renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(NatureGlass.accent).frame(width: compact ? 28 : 40, height: compact ? 28 : 40).accessibilityHidden(true)
          Text("engima").font(.system(size: compact ? 15 : 19, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
          Spacer(minLength: 0)
          Button { isSidebarVisible = false } label: {
            Image(systemName: "sidebar.left").font(.system(size: 14)).frame(width: 24, height: 32)
          }.buttonStyle(NatureButtonStyle()).accessibilityLabel("Hide chat history")
            .help("Hide chat history · double-tap Control")
          Button {
            NotificationCenter.default.post(name: .newChatRequested, object: nil)
          } label: {
            Image(systemName: "square.and.pencil").font(.system(size: 17))
              .foregroundStyle(NatureGlass.accent).frame(width: 36, height: 36)
              .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
              .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.19)) }
          }.buttonStyle(NatureButtonStyle()).accessibilityLabel("New chat")
        }
        .padding(.horizontal, compact ? 0 : 8)

        VStack(spacing: 4) {
          if localChat.sessions.isEmpty {
            sidebarRow(title: "New Chat", selected: true, compact: compact) {
              NotificationCenter.default.post(name: .newChatRequested, object: nil)
            }
          }
          ForEach(localChat.sessions.prefix(5)) { session in
            sidebarRow(title: session.title, date: session.messages.isEmpty ? nil : session.lastActivityAt,
                       selected: localChat.selectedSessionID == session.id, compact: compact) {
              localChat.selectSession(id: session.id)
            }
          }
        }

        VStack(alignment: .leading, spacing: 0) {
          Divider().overlay(NatureGlass.secondary.opacity(0.25)).padding(.horizontal, 16)
          Button { isHelpPresented = true } label: {
            Label("Help", systemImage: "questionmark.circle")
              .frame(maxWidth: .infinity, alignment: .leading).frame(height: 42).contentShape(Rectangle())
          }.buttonStyle(NatureButtonStyle())
          Button(action: openSettings) {
            Label("Settings", systemImage: "gearshape")
              .frame(maxWidth: .infinity, alignment: .leading).frame(height: 42).contentShape(Rectangle())
          }.buttonStyle(NatureButtonStyle())
          DeveloperToolsView(glassAppearance: glassAppearance, advisor: modelAdvisor, chat: localChat)
            .padding(.vertical, 16)
        }
        .font(.system(size: compact ? 13 : 14))
        .padding(.horizontal, compact ? 12 : 24)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 20)
    }
    .scrollIndicators(.hidden)
    .modifier(NatureGlassSurface(navigation: true, enabled: glassAppearance.isEnabled, clarity: glassAppearance.clarity))
    .padding(12)
  }

  private func sidebarRow(title: String, date: Date? = nil, selected: Bool, compact: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: compact ? 10 : 16) {
        Image(systemName: "bubble.left").font(.system(size: 16)).frame(width: 20)
          .foregroundStyle(selected ? NatureGlass.accent : NatureGlass.primary)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.system(size: compact ? 13 : 14, weight: selected ? .medium : .regular)).lineLimit(1)
          if let date {
            Text(date, format: .dateTime.month(.abbreviated).day()).font(.system(size: 11)).foregroundStyle(NatureGlass.secondary)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, compact ? 12 : 24).frame(height: compact ? 42 : (date == nil ? 46 : 52))
      .background(selected ? NatureGlass.accent.opacity(0.14) : .clear, in: Capsule())
      .overlay { if selected { Capsule().strokeBorder(NatureGlass.accent.opacity(0.2)) } }
      .overlay(alignment: .leading) {
        if selected { Capsule().fill(NatureGlass.accent).frame(width: 2, height: 40) }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(NatureButtonStyle())
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func composer(compact: Bool) -> some View {
    let isResponding = localChat.activeRequest != nil
    return HStack(spacing: compact ? 8 : 16) {
      FileModeToolButton(files: files, isBusy: localChat.isBusy) { activateFileMode(from: .menu) }
      Rectangle().fill(NatureGlass.secondary.opacity(0.35)).frame(width: 1, height: 40)

      SlashCommandComposer(
        text: Binding(get: { localChat.pendingUserMessage == nil ? screen.draft : "" },
                      set: { screen.draft = $0 }),
        isFocused: Binding(get: { isComposerFocused }, set: { isComposerFocused = $0 }),
        isEnabled: !(localChat.isBusy || screen.isBusy || files.isWorking || files.isPicking),
        fontSize: compact ? 14 : 15,
        submit: submitDraft
      )

      Button { isModePalettePresented.toggle() } label: {
        HStack(spacing: 8) {
          if !compact { Image(systemName: selectedMode.systemImage) }
          Text(selectedMode.displayName)
          Image(systemName: "chevron.down").font(.system(size: 10))
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, compact ? 8 : 12).frame(height: compact ? 32 : 38)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)) }
      }.buttonStyle(NatureButtonStyle()).fixedSize().accessibilityLabel("Mode and model")

      Button {
        if isResponding { localChat.stopStreaming() } else { submitDraft() }
      } label: {
        Image(systemName: isResponding ? "stop.fill" : "paperplane.fill")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(NatureGlass.canvas)
          .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
          .background(NatureGlass.accent, in: Circle())
          .overlay { Circle().strokeBorder(.white.opacity(0.48)) }
      }
      .buttonStyle(NatureButtonStyle())
      .disabled(!isResponding && (!canSubmit || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || screen.isBusy || files.isWorking || files.isPicking))
      .accessibilityLabel(isResponding ? "Stop response" : "Send message")
    }
    .padding(.leading, 12).padding(.trailing, compact ? 10 : 12).padding(.vertical, compact ? 10 : 12)
    .modifier(NatureGlassSurface(radius: 44, enabled: glassAppearance.isEnabled, clarity: glassAppearance.clarity))
    .overlay {
      if localChat.activeRequest != nil { ThinkingComposerGlow().allowsHitTesting(false) }
    }
    .shadow(color: NatureGlass.accent.opacity(isComposerFocused ? 0.08 : 0), radius: 12)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isComposerFocused)
  }

  @ViewBuilder
  private var conversation: some View {
    if localChat.presentationMessages.isEmpty && localChat.activeRequest == nil {
      GeometryReader { geometry in
        let compact = geometry.size.height < 370
        VStack(spacing: compact ? 12 : 24) {
          Spacer(minLength: 8)
          if geometry.size.height >= 250 {
            Image("SpotlightLogo")
              .renderingMode(.template).resizable().scaledToFit()
              .frame(width: compact ? 72 : 120, height: compact ? 72 : 120)
              .foregroundStyle(NatureGlass.accent)
              .shadow(color: NatureGlass.accent.opacity(0.22), radius: 16)
              .accessibilityHidden(true)
          }
          Text("How can I help?")
            .font(.system(size: compact ? 23 : 32, weight: .semibold)).tracking(-0.8)
          compactModeControls
          if selectedMode == .local && localChat.installedModel == nil {
            Button("Choose GGUF Model") { isModelImporterPresented = true }
              .buttonStyle(.borderedProminent).disabled(localChat.isBusy)
          }
          Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          ForEach(localChat.presentationMessages) { message in
            LocalMessageView(message: message, isThinking: localChat.isWaitingForResponse && message.id == localChat.presentationMessages.last?.id,
                             expandedActivity: activityExpansion(message.activity?.id ?? message.id))
              .id(message.id)
            if message.role == .assistant, !message.content.isEmpty, !localChat.isBusy,
               !localChat.attachedContexts.isEmpty, selectionContext.canReplace {
              Button("Replace Selection") { replacementText = message.content; replacementMessage = message }
                .buttonStyle(.bordered).controlSize(.small)
            }
          }
          if let activity = localChat.activity, localChat.presentationMessages.last?.role != .assistant {
            AssistantActivityView(activity: activity, expanded: activityExpansion(activity.id))
          }
        }
        .padding(24)
        .background(ConversationScrollObserver(contentRevision: (localChat.presentationMessages.last?.content ?? "") + String(localChat.presentationMessages.count) + (localChat.activity?.status ?? "") + String(expandedActivities.count)).allowsHitTesting(false))
      }
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .defaultScrollAnchor(.top, for: .alignment)
      .id(localChat.selectedSessionID)
    }
  }

  @ViewBuilder
  private var routeStatus: some View {
    if let request = localChat.activeRequest {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("\(requestPhase) · \(request.displayName)")
          .lineLimit(2)
        Button("Stop") { localChat.stopStreaming() }
          .buttonStyle(.plain)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .trailing)
    } else {
      inactiveRouteStatus
    }
  }

  private func activityExpansion(_ id: UUID) -> Binding<Bool> {
    Binding(get: { expandedActivities.contains(id) }, set: { expanded in
      if expanded { expandedActivities.insert(id) } else { expandedActivities.remove(id) }
    })
  }

  private var requestPhase: String { localChat.activity?.status ?? "Preparing…" }

  @ViewBuilder
  private var inactiveRouteStatus: some View {
    switch selectedMode {
    case .local:
      HStack(spacing: 8) {
        switch localChat.state {
        case .benchmarking:
          ProgressView().controlSize(.small)
          Text("Checking model performance…")
        case .installing:
          ProgressView()
            .controlSize(.small)
          Text("Installing local model…")
        case .deleting:
          ProgressView()
            .controlSize(.small)
          Text("Deleting local model…")
        case .downloading(let progress):
          ProgressView(value: progress.fractionCompleted)
            .frame(width: 72)
          Text("Downloading \(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))")
        case .preparing, .refiningSearch, .searching:
          ProgressView()
            .controlSize(.small)
          Text("Loading local model…")
        case .streaming:
          ProgressView()
            .controlSize(.small)
          Text("Generating locally")
          Button("Stop") {
            localChat.stopStreaming()
          }
          .buttonStyle(.plain)
        case .failed(let message):
          Image(systemName: "exclamationmark.triangle")
          Text(message)
            .lineLimit(2)
        case .idle:
          if let model = localChat.installedModel {
            Image(systemName: "checkmark.circle")
            Text(model.displayName)
              .lineLimit(1)
            modelMenu
          } else {
            Text("A local GGUF model is required.")
            modelMenu
          }
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .trailing)
    case .cloud:
      HStack(spacing: 8) {
        if !cloudSettings.hasCloudAccess(for: cloudSettings.preferredProvider) {
          Text(cloudSettings.preferredProvider == .chatGPT
            ? "Sign in with ChatGPT to use your Codex allowance."
            : "Add a \(cloudSettings.preferredProvider.displayName) API key.")
          Button("Advanced Settings", action: openSettings)
        } else if !cloudSettings.isConfigured {
          Text(cloudSettings.selectedModelCompatibility.message)
            .lineLimit(2)
          Button("Advanced Settings", action: openSettings)
        } else {
          switch localChat.state {
          case .preparing, .refiningSearch, .searching:
            ProgressView()
              .controlSize(.small)
            Text("Connecting to \(cloudSettings.preferredProvider.displayName)…")
          case .streaming:
            ProgressView()
              .controlSize(.small)
            Text("Streaming from \(cloudSettings.preferredProvider.displayName)")
            Button("Stop") { localChat.stopStreaming() }
              .buttonStyle(.plain)
          case .failed(let message):
            Image(systemName: "exclamationmark.triangle")
            Text(message)
              .lineLimit(2)
          case .idle:
            Image(systemName: "cloud")
            Text("\(cloudSettings.preferredProvider.displayName) · \(cloudSettings.preferredModelID)")
              .lineLimit(1)
            if cloudSettings.selectedModelCompatibility == .unverified {
              Text("Unverified")
                .help(cloudSettings.selectedModelCompatibility.message)
            }
          case .installing, .deleting, .downloading, .benchmarking:
            Text("Finish the local model task before using Cloud mode.")
          }
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .trailing)
    case .auto:
      autoRouteStatus
    }
  }

  @ViewBuilder
  private var autoRouteStatus: some View {
    HStack(spacing: 8) {
      if case .failed(let message) = localChat.state {
        Image(systemName: "exclamationmark.triangle")
        Text(message)
          .lineLimit(2)
      } else if let decision = localChat.autoRouteDecision {
        if let route = decision.route {
          Image(systemName: route.mode == .local ? "laptopcomputer" : "cloud")
          Text("Auto · \(route.mode.displayName) · \(decision.modelDisplayName ?? route.modelID)")
            .lineLimit(1)
          if localChat.state == .preparing || localChat.state == .streaming {
            ProgressView()
              .controlSize(.small)
          }
          if localChat.state == .streaming {
            Button("Stop") { localChat.stopStreaming() }
              .buttonStyle(.plain)
          }
        } else if let limitation = decision.limitation {
          Image(systemName: "exclamationmark.triangle")
          Text(limitation.message)
            .lineLimit(2)
        }
      } else if let model = localChat.installedModel, autoCloudConfiguration == nil {
        Image(systemName: "laptopcomputer")
        Text("Cloud isn’t connected; Auto stays local · \(model.displayName)")
          .lineLimit(1)
      } else if localChat.installedModel != nil || autoCloudConfiguration != nil {
        Image(systemName: "sparkles")
        Text("Auto chooses the lowest-latency capable model.")
      } else {
        Text("Choose a local model or connect Cloud to use Auto.")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private var compactModeControls: some View {
    HStack(spacing: 0) {
      ForEach(ChatMode.allCases) { mode in
        Button { selectedMode = mode } label: {
          Label(mode.displayName, systemImage: mode.systemImage)
            .font(.system(size: 14, weight: .medium))
            .frame(maxWidth: .infinity).frame(height: 38)
            .foregroundStyle(selectedMode == mode ? NatureGlass.canvas : NatureGlass.primary)
            .background(selectedMode == mode ? NatureGlass.accent : .clear, in: Capsule())
        }
        .buttonStyle(NatureButtonStyle())
        .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
      }
    }
    .padding(8).frame(maxWidth: 320)
    .modifier(NatureGlassSurface(radius: 32, enabled: glassAppearance.isEnabled, clarity: glassAppearance.clarity))
    .padding(.horizontal, 16)
    .accessibilityLabel("Routing mode")
  }

  private var modePalette: some View {
    ZStack {
      Color.black.opacity(0.12)
        .ignoresSafeArea()
        .onTapGesture {
          isModePalettePresented = false
          isComposerFocused = true
        }

      VStack(alignment: .leading, spacing: 8) {
        Text(localChat.activeRequest == nil ? "Mode & Model" : "Next request · Mode & Model")
          .font(.headline)
          .padding(.bottom, 2)

        ForEach(ChatMode.allCases) { mode in
          Button {
            selectedMode = mode
            isModePalettePresented = false
            isComposerFocused = true
          } label: {
            HStack(spacing: 10) {
              Image(systemName: mode.systemImage)
                .frame(width: 18)
              Text(mode.displayName)
              Spacer()
              if selectedMode == mode {
                Image(systemName: "checkmark")
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(NatureButtonStyle())
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
        }

        Divider()

        Group {
          switch selectedMode {
          case .local:
            modelMenu
          case .cloud:
            cloudModelMenu
          case .auto:
            Text("Auto keeps routine tasks local and uses Cloud only when needed.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
      }
      .padding(14)
      .frame(width: 300)
      .natureSurface(radius: 24)
    }
  }

  private var canSubmit: Bool {
    switch selectedMode {
    case .local:
      localChat.installedModel != nil && !localChat.isBusy
    case .cloud:
      cloudSettings.isConfigured && !localChat.isBusy
    case .auto:
      (localChat.installedModel != nil || autoCloudConfiguration != nil) && !localChat.isBusy
    }
  }

  private var welcomeSubtitle: String {
    if isSearchEnabled {
      return selectedMode == .local
        ? "Brave finds web sources. Your local model writes the answer on this Mac."
        : "Brave finds web sources for your selected model to answer with citations."
    }
    if searchSettings.canSearchAutomatically && files.selection == nil {
      return "Questions needing fresh information search Brave automatically. Your selected model writes the answer."
    }
    if selectedMode == .local {
      return localChat.installedModel == nil
        ? "Choose a GGUF model once, then chat completely offline."
        : "Runs on this Mac with no network requests."
    }
    if selectedMode == .cloud {
      if cloudSettings.preferredProvider == .chatGPT {
        return cloudSettings.isConfigured
          ? "Uses your ChatGPT plan's Codex allowance. Usage limits apply."
          : "Sign in with ChatGPT in Settings—no API key needed."
      }
      return cloudSettings.isConfigured
        ? "Uses \(cloudSettings.preferredProvider.displayName) with a stateless request."
        : "Add a provider key and model in Advanced Settings."
    }
    if localChat.installedModel != nil, autoCloudConfiguration == nil {
      return "Cloud is not connected, so Auto stays on this Mac."
    }
    return "Local-first assistance that uses Cloud only when it is needed."
  }

  private var modelMenu: some View {
    Menu {
      if localChat.installedModels.isEmpty {
        Text("No installed models")
      } else {
        Section("Installed") {
          ForEach(localChat.installedModels) { model in
            Button {
              localChat.selectModel(id: model.id)
            } label: {
              Label(
                model.displayName + (model.supportsVision ? " · Text + images" : " · Text only"),
                systemImage: localChat.installedModel?.id == model.id ? "checkmark" : "cpu"
              )
            }
          }
        }
      }

      Button("Find a Model for This Mac…") {
        Task { await modelAdvisor.replayOnboarding() }
      }
      Button("Manage Models in Settings…", action: openSettings)

      Divider()
      Button("Advanced: Import Text GGUF…") {
        isModelImporterPresented = true
      }
    } label: {
      Label(localChat.installedModel?.displayName ?? "Choose Model", systemImage: "cpu")
    }
    .menuStyle(.borderlessButton)
    .disabled(localChat.isBusy)
  }

  private var cloudModelMenu: some View {
    Menu {
      if cloudSettings.models.isEmpty {
        Text("No discovered models")
      } else {
        Section(cloudSettings.preferredProvider.displayName) {
          ForEach(cloudSettings.models) { model in
            Button {
              cloudSettings.preferredModelID = model.id
            } label: {
              Label(
                model.displayName + (model.supportsVision ? " · Text + images" : " · Text only"),
                systemImage: cloudSettings.preferredModelID == model.id ? "checkmark" : "cloud"
              )
            }
          }
        }
      }

      Divider()
      Button(action: openSettings) {
        Label("Advanced Settings…", systemImage: "gearshape")
      }
    } label: {
      Label(
        cloudSettings.preferredModelID.isEmpty ? "Choose Cloud Model" : cloudSettings.preferredModelID,
        systemImage: "cloud"
      )
    }
    .menuStyle(.borderlessButton)
    .disabled(localChat.isBusy)
  }

  private var fileAccess: FileAccessLevel {
    if selectedMode == .cloud { return cloudSettings.preferredProvider == .chatGPT ? .readWrite : .readOnly }
    return localChat.installedModel.map { LocalFileCapabilities.production.access(for: $0) } ?? .readOnly
  }

  private func activateFileMode(from source: FileModeCoordinator.Activation) {
    guard !localChat.isBusy, !screen.isBusy else { return }
    Task {
      await files.activate(from: source)
      if files.selection != nil {
        screen.removeAttachment()
        isSearchEnabled = false
      }
      isComposerFocused = true
    }
  }

  private func captureScreen() {
    guard !localChat.isBusy else { return }
    Task {
      _ = await screen.capture()
      isComposerFocused = true
    }
  }

  private func submitDraft() {
    guard !localChat.isBusy, !screen.isBusy, !files.isWorking, !files.isPicking else { return }
    let commands = ComposerCommands(draft)
    if files.selection != nil {
      if screen.isEnabled || isSearchEnabled || commands.screen || commands.search {
        files.error = "Turn off Screen and Web Search to work with your attached files."
        return
      }
      let prompt = draft
      localChat.submitFiles(prompt, mode: selectedMode, cloudProvider: cloudSettings.preferredProvider,
        cloudModelID: cloudSettings.preferredModelID) { if draft == prompt { draft = "" } }
      return
    }
    // Capture can finish and submit again before SwiftUI delivers onChange.
    // Resolve all requested tools now; no view-update timing controls routing.
    if commands.search {
      isSearchPresented = true
      isSearchEnabled = true
    }
    if commands.screen {
      Task {
        let automaticPrompt = await screen.capture(submittedCommand: true)
        isComposerFocused = true
        if automaticPrompt != nil { submitDraft() }
      }
      return
    }
    if screen.isEnabled, let attachment = screen.attachment {
      submitScreenAttachment(attachment)
      return
    }
    guard canSubmit, !commands.prompt.isEmpty else { return }
    let originalDraft = draft
    let prompt = commands.submissionPrompt
    let accepted: @MainActor () -> Void = {
      if draft == originalDraft { draft = "" }
    }
    switch selectedMode {
    case .local:
      localChat.submit(prompt, searchEnabled: isSearchEnabled, onAccepted: accepted)
    case .cloud:
      localChat.submitCloud(
        prompt,
        provider: cloudSettings.preferredProvider,
        modelID: cloudSettings.preferredModelID,
        searchEnabled: isSearchEnabled,
        onAccepted: accepted
      )
    case .auto:
      localChat.submitAuto(prompt, cloud: autoCloudConfiguration, searchEnabled: isSearchEnabled, onAccepted: accepted)
    }
  }

  private func submitScreenAttachment(_ attachment: ScreenAttachment) {
    let originalDraft = draft
    let commands = ComposerCommands(draft)
    guard !commands.prompt.isEmpty else { return }
    let prompt = commands.submissionPrompt
    let cloudText = cloudSettings.isConfigured
      ? CloudModel(id: cloudSettings.preferredModelID, displayName: cloudSettings.preferredModelID,
                   provider: cloudSettings.preferredProvider).screenModel : nil
    let searchEnabled = localChat.shouldSearch(prompt, explicitlyEnabled: isSearchEnabled)
    let automatic = selectedMode == .auto ? AutoRouter.decide(AutoRouter.Request(
      selectedMode: .auto, webSearchEnabled: searchEnabled, prompt: prompt,
      contextMessages: localChat.messages, localModel: localChat.installedModel,
      additionalInputTokens: attachment.ocrText.utf8.count + 512
        + (ScreenRoutingPolicy.requiresVision(prompt: prompt, ocr: ScreenOCRResult(text: attachment.ocrText,
          confidence: attachment.ocrConfidence)) ? 4096 : 0),
      cloud: connectivity.isOffline ? nil : autoCloudConfiguration)) : nil
    if let limitation = automatic?.limitation {
      screen.error = limitation.message
      return
    }
    let request = ScreenRoutingPolicy.Request(
      prompt: prompt, ocr: ScreenOCRResult(text: attachment.ocrText, confidence: attachment.ocrConfidence),
      mode: selectedMode, localText: localChat.installedModel?.screenModel, cloudText: cloudText,
      autoRoute: automatic?.route,
      allowCloudScreenshots: screenSettings.allowCloudScreenshots,
      hasExplainedCloudPermission: screenSettings.hasExplainedCloudPermission, isOffline: connectivity.isOffline
    )
    let decision = ScreenRoutingPolicy.decide(request)
    screen.updateDecision(decision)
    screen.error = nil
    switch decision {
    case .needsCloudPermission:
      isScreenPermissionPresented = true
    case .blocked(let reason):
      screen.error = reason
    case .text, .vision:
      localChat.submitScreen(prompt, attachment: attachment, decision: decision, selectedMode: selectedMode,
        searchEnabled: searchEnabled,
        cloudUploadAllowed: { screenSettings.allowCloudScreenshots && screenSettings.hasExplainedCloudPermission }) {
          if draft == originalDraft { draft = "" }
          if screen.attachment?.id == attachment.id { screen.removeAttachment() }
          isComposerFocused = true
        }
    }
  }

  private var autoCloudConfiguration: AutoRouter.CloudConfiguration? {
    guard cloudSettings.isConfigured else { return nil }
    let modelID = cloudSettings.preferredModelID
    let displayName = cloudSettings.models.first(where: { $0.id == modelID })?.displayName ?? modelID
    return AutoRouter.CloudConfiguration(
      provider: cloudSettings.preferredProvider,
      modelID: modelID,
      modelDisplayName: displayName
    )
  }

  private func openSettings() {
    isModePalettePresented = false
    isComposerFocused = false
    NotificationCenter.default.post(name: .settingsRequested, object: nil)
  }
}

enum ChatTypography {
  static let body = Font.system(size: 14)
  static let label = Font.system(size: 11, weight: .semibold)
}

struct LocalMessageView: View {
  let message: ChatMessage
  var isThinking = false
  var expandedActivity: Binding<Bool>? = nil

  var body: some View {
    Group {
      if message.role == .user {
        HStack(alignment: .top, spacing: 0) {
          Spacer(minLength: 48)
          VStack(alignment: .trailing, spacing: 8) {
            if let attachments = message.attachments {
              ForEach(attachments.indices, id: \.self) { index in
                Label(attachments[index].name, systemImage: attachments[index].isDirectory ? "folder" : "doc")
                  .font(ChatTypography.label)
                  .lineLimit(2)
                  .padding(.horizontal, 10).padding(.vertical, 6)
                  .background(NatureGlass.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
              }
            }
            if let data = message.imagePreview, let image = NSImage(data: data) {
              SentImagePreview(image: image)
            }
            Text(verbatim: message.content)
              .font(ChatTypography.body)
              .textSelection(.enabled)
              .padding(.horizontal, 16).padding(.vertical, 12)
              .background(NatureGlass.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 18))
              .overlay { RoundedRectangle(cornerRadius: 18).stroke(NatureGlass.edge, lineWidth: 0.6) }
              .accessibilityLabel("You: " + message.content)
          }
          .frame(maxWidth: 560, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          if let activity = message.activity {
            AssistantActivityView(activity: activity, expanded: expandedActivity)
          } else if let sources = message.searchSources, !sources.isEmpty {
            AssistantActivityView(activity: .savedSources(sources, messageID: message.id), expanded: expandedActivity)
          } else if message.content.isEmpty && isThinking {
            ThinkingStatusView().allowsHitTesting(false)
          }
          if !message.content.isEmpty {
            ChatMarkdownView(content: message.content)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct SentImagePreview: View {
  let image: NSImage

  var body: some View {
    let scale = min(1, 120 / max(1, image.size.width), 96 / max(1, image.size.height))
    Image(nsImage: image)
      .resizable()
      .scaledToFit()
      .frame(width: image.size.width * scale, height: image.size.height * scale)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1)))
      .accessibilityLabel("Image attached to your message")
  }
}

private extension ChatMode {
  var systemImage: String {
    switch self {
    case .auto: "bolt"
    case .local: "laptopcomputer"
    case .cloud: "cloud"
    }
  }
}

private struct KeyboardShortcutsHelpView: View {
  @AppStorage(SelectionShortcutMonitor.modifierKey) private var selectionModifier = SelectionModifier.option.rawValue
  @AppStorage(SelectionShortcutMonitor.enabledKey) private var doubleOptionEnabled = true
  @AppStorage(SelectionShortcutMonitor.intervalKey) private var doubleOptionInterval = 0.35
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("Keyboard Shortcuts", systemImage: "keyboard")
        .font(.title2.weight(.medium))

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Anywhere on your Mac")
            .font(.headline)
          shortcut("New temporary chat with selection", keys: "\((SelectionModifier(rawValue: selectionModifier) ?? .option).symbol) twice")
          shortcut("Selection Context backup", keys: "⇧ ⌥ Space")
          Toggle("Enable double-tap shortcut", isOn: $doubleOptionEnabled)
          Picker("Selection shortcut key", selection: $selectionModifier) {
            ForEach(SelectionModifier.allCases) { modifier in Text(modifier.title).tag(modifier.rawValue) }
          }
          Picker("Double-tap interval", selection: $doubleOptionInterval) {
            Text("Fast").tag(0.25)
            Text("Normal").tag(0.35)
            Text("Relaxed").tag(0.5)
          }
          Text("Highlight text in another app, then tap the chosen key twice by itself (Option by default). Context stays in a temporary chat and follows your selected model and Web Search settings. Replace Selection is available only while the original target can be verified. Password fields are excluded.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Enable Accessibility…") {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
          }
          shortcut("Show or hide engima", keys: "⌥ Space")
          shortcut("Open Advanced Settings", keys: "⌥ S")

          Divider()

          Text("In the chat panel")
            .font(.headline)
          shortcut("Hide the panel", keys: "Esc")
          shortcut("New chat", keys: "⌘ N")
          shortcut("Open or close Mode & Model", keys: "⌘ K")
          shortcut("Stop the response", keys: "⌘ .")
          shortcut("Next recent chat", keys: "⌃ Tab")
          shortcut("Show or hide chat history", keys: "⌃ twice")
          shortcut("Open Settings", keys: "⌘ ,")
          shortcut("Send from the message field", keys: "Return")
          shortcut("Complete a slash command", keys: "Tab / Return")
          shortcut("Choose a command suggestion", keys: "↑ / ↓")
          shortcut("Dismiss command suggestions", keys: "Esc")
          shortcut("Insert a new line", keys: "⇧ Return")
          shortcut("Hide inactive tools", keys: "⇧ ⌘ H")
          shortcut("Enable Web Search", keys: "/search")
          shortcut("Capture the full desktop", keys: "/screen")
          shortcut("Capture a screen region", keys: "/snapshot")
          shortcut("Think harder for this answer", keys: "/think")
          shortcut("Attach files or a folder", keys: "⇧ ⌥ F")
          Text("/screen captures all displays; /snapshot selects a region. Add a question to capture and send, or use the command alone to attach. /think applies to one answer. Commands can appear anywhere in your message and remain blue in the input. Put literal command examples in quotes or backticks.")
            .font(.caption).foregroundStyle(.secondary)

          Divider()

          Text("Editing text")
            .font(.headline)
          shortcut("Select all", keys: "⌘ A")
          shortcut("Copy", keys: "⌘ C")
          shortcut("Cut", keys: "⌘ X")
          shortcut("Paste", keys: "⌘ V")
          shortcut("Undo", keys: "⌘ Z")
          shortcut("Redo", keys: "⇧ ⌘ Z")

          Text("⌘ Command · ⌥ Option · ⌃ Control · ⇧ Shift")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.trailing, 4)
      }

      HStack {
        Spacer()
        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 460, height: 400)
    .naturePresentation()
    .onExitCommand { dismiss() }
  }

  private func shortcut(_ title: String, keys: String) -> some View {
    HStack {
      Text(title)
      Spacer(minLength: 16)
      Text(keys)
        .font(.body.monospaced())
        .foregroundStyle(.secondary)
    }
  }
}

private struct DeveloperToolsView: View {
  @ObservedObject var glassAppearance: GlassAppearanceSettings
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        Button("Detect Mac Capabilities") { Task { await advisor.detectHardware() } }
          .disabled(advisor.isDetecting || chat.isBusy)
        Button("Test First-Run Model Selection") { Task { await advisor.replayOnboarding() } }
          .disabled(advisor.isDetecting || chat.isBusy)
        if let hardware = advisor.hardware {
          Text("\(hardware.chip) · \(hardware.cpuCount) CPUs")
          Text("Inference budget: \(hardware.inferenceMemoryBudget, format: .byteCount(style: .memory))")
          Text("Free disk: \(hardware.availableDiskBytes, format: .byteCount(style: .file))")
          Text(hardware.hasMetal ? "Metal available" : "CPU inference")
          if let limit = hardware.metalRecommendedWorkingSet {
            Text("Metal working set: \(limit, format: .byteCount(style: .memory))")
          }
        }
        Divider()
        Toggle("Liquid Glass", isOn: $glassAppearance.isEnabled)

        if glassAppearance.isEnabled {
          HStack {
            Text("Glass clarity")
            Spacer()
            Text(glassAppearance.clarity, format: .percent.precision(.fractionLength(0)))
              .foregroundStyle(.secondary)
          }
          .font(.caption)

          Slider(value: $glassAppearance.clarity, in: 0...1, step: 0.01)
            .accessibilityLabel("Glass clarity")

          Text("100% is completely clear.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Button("Save") {
          glassAppearance.save()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!glassAppearance.hasUnsavedChanges)
      }
      .padding(.top, 8)
    } label: {
      Label("Developer Tools", systemImage: "wrench.and.screwdriver")
        .font(.callout.weight(.medium))
    }
  }
}

struct SettingsView: View {
  @ObservedObject private var settings: CloudSettingsModel
  @State private var openAIAPIKey = ""
  @State private var anthropicAPIKey = ""
  @State private var geminiAPIKey = ""
  @State private var formError: String?

  init(settings: CloudSettingsModel = .shared, initialDestination: SettingsDestination = .local) {
    self.settings = settings
    _destination = State(initialValue: initialDestination)
  }

  @State private var destination: SettingsDestination
  enum SettingsDestination: String, CaseIterable, Identifiable {
    case local = "Local Models"
    case cloud = "Cloud & Search"
    var id: Self { self }
    var symbol: String { self == .local ? "laptopcomputer" : "cloud" }
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 28) {
        HStack(spacing: 12) {
          Image("SpotlightLogo").renderingMode(.template).resizable().scaledToFit()
            .frame(width: 36, height: 36).foregroundStyle(NatureGlass.accent)
          Text("Settings").font(.system(size: 20, weight: .semibold))
        }.padding(.horizontal, 12)
        VStack(spacing: 8) {
          ForEach(SettingsDestination.allCases) { item in
            Button { destination = item } label: {
              Label(item.rawValue, systemImage: item.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(destination == item ? NatureGlass.accent.opacity(0.14) : .clear, in: Capsule())
                .overlay { if destination == item { Capsule().strokeBorder(NatureGlass.accent.opacity(0.2)) } }
            }.buttonStyle(NatureButtonStyle())
              .accessibilityAddTraits(destination == item ? .isSelected : [])
          }
        }
        Spacer()
        Text("engima").font(.caption).foregroundStyle(NatureGlass.secondary).padding(16)
      }
      .padding(12).frame(width: 208)
      .natureSurface(navigation: true).padding(12)
      VStack(alignment: .leading, spacing: 8) {
        Text(destination.rawValue).font(.system(size: 24, weight: .semibold)).padding(.horizontal, 20).padding(.top, 24)
        Text(destination == .local ? "Intelligence, right on your Mac." : "Connect your models and the web.")
          .foregroundStyle(NatureGlass.secondary).padding(.horizontal, 20)
        Group {
          switch destination {
          case .local:
            Form { LocalModelManagerSection() }.formStyle(.grouped)
          case .cloud:
            cloudForm
          }
        }
        .scrollContentBackground(.hidden)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 24))
        .padding(.top, 12)
      }
      .padding(.trailing, 20).padding(.bottom, 20)
    }
    .frame(width: 820, height: 680)
    .naturePresentation()
  }

  private var cloudForm: some View {
    Form {
      Section("ChatGPT Subscription") {
        if let account = settings.chatGPTAccount {
          Label(account.email ?? "Signed in with ChatGPT", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
          HStack {
            Button("Use ChatGPT") {
              settings.preferredProvider = .chatGPT
              Task { await settings.discoverModels() }
            }
            Button("Sign Out", role: .destructive) {
              Task { await settings.signOutOfChatGPT() }
            }
          }
        } else if settings.isSigningIn {
          HStack {
            ProgressView().controlSize(.small)
            Text("Finish signing in in your browser…")
            Button("Cancel") { settings.cancelSignIn() }
          }
        } else {
          Button("Sign in with ChatGPT") {
            settings.signInWithChatGPT { url in
              await MainActor.run { NSWorkspace.shared.open(url) }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!settings.isCodexAvailable)
        }

        Text("Uses your ChatGPT plan's Codex allowance, not API billing. Plan limits and model availability apply. This is a Codex-powered chat, not the ChatGPT website.")
          .font(.caption)
          .foregroundStyle(.secondary)

        if !settings.isCodexAvailable {
          Text("The Codex CLI is required on this Mac. Install or update it, then check again.")
            .font(.caption)
          Link("Codex installation instructions", destination: URL(string: "https://learn.chatgpt.com/docs/cli")!)
        }

        Button("Check Sign-in Status") {
          Task { await settings.refreshChatGPTAccount() }
        }
        .disabled(settings.isSigningIn)

        Text("Sign-in is stored by Codex in macOS Keychain, separately from the Codex app. No Apple development team or backend is needed.")
          .font(.caption)
          .foregroundStyle(.secondary)

        if let accountError = settings.accountError {
          Text(accountError).font(.caption).foregroundStyle(.red)
        }
      }

      ScreenSettingsSection(settings: .shared)

      WebSearchSettingsSection(settings: .shared)

      Section("Advanced Cloud Settings") {
        Picker("Preferred provider", selection: $settings.preferredProvider) {
          ForEach(CloudProviderID.allCases) { provider in
            Text(provider.displayName).tag(provider)
          }
        }

        if settings.models.isEmpty {
          Text(settings.modelDiscoveryNotice
            ?? "Refresh models to find compatible chat choices, or enter a model ID manually.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Picker("Preferred model", selection: $settings.preferredModelID) {
            if settings.preferredModelID.isEmpty {
              Text("Choose a model").tag("")
            }
            ForEach(settings.models) { model in
              Text(model.displayName).tag(model.id)
            }
            if !settings.preferredModelID.isEmpty,
               !settings.models.contains(where: { $0.id == settings.preferredModelID }) {
              Text("Manual · \(settings.preferredModelID)").tag(settings.preferredModelID)
            }
          }
        }

        TextField("Manual model ID", text: $settings.preferredModelID)
          .textFieldStyle(.roundedBorder)

        Text(settings.selectedModelCompatibility.message)
          .font(.caption)
          .foregroundStyle(settings.selectedModelCompatibility == .unsupported ? Color.red : Color.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if settings.preferredProvider == .chatGPT {
          Picker("Thinking capacity", selection: $settings.codexThinkingCapacity) {
            ForEach(CodexThinkingCapacity.allCases) { capacity in
              Text(capacity.displayName).tag(capacity)
            }
          }
        }

        HStack {
          Button(settings.isDiscovering ? "Refreshing…" : "Refresh Models") {
            Task { await settings.discoverModels(forceRefresh: true) }
          }
          .disabled(
            settings.isDiscovering
              || !settings.hasCloudAccess(for: settings.preferredProvider)
          )
          if settings.isDiscovering {
            ProgressView()
              .controlSize(.small)
          }
        }

        if let discoveryError = settings.discoveryError {
          Text(discoveryError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Section("OpenAI API Key · Separate Billing") {
        SecureField(
          settings.hasAPIKey(for: .openAI) ? "Replace stored API key" : "API key",
          text: $openAIAPIKey
        )
        .textFieldStyle(.roundedBorder)

        credentialButtons(provider: .openAI, apiKey: $openAIAPIKey)
        connectionStatus(for: .openAI)

        Text("OpenAI API usage requires separate API billing; a ChatGPT subscription does not include API access.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Anthropic API Key · Separate Billing") {
        SecureField(
          settings.hasAPIKey(for: .anthropic) ? "Replace stored API key" : "API key",
          text: $anthropicAPIKey
        )
        .textFieldStyle(.roundedBorder)

        credentialButtons(provider: .anthropic, apiKey: $anthropicAPIKey)
        connectionStatus(for: .anthropic)
      }

      Section("Gemini API Key") {
        SecureField(settings.hasAPIKey(for: .gemini) ? "Replace stored API key" : "API key", text: $geminiAPIKey)
          .textFieldStyle(.roundedBorder)
        credentialButtons(provider: .gemini, apiKey: $geminiAPIKey)
        connectionStatus(for: .gemini)
      }

      if let formError {
        Text(formError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("engima Settings")
    .task {
      await settings.refreshChatGPTAccount()
      await settings.loadCachedModels()
      if settings.hasCloudAccess(for: settings.preferredProvider), settings.models.isEmpty {
        await settings.discoverModels()
      }
    }
    .onChange(of: settings.preferredProvider) { _, provider in
      Task {
        if provider == .chatGPT { await settings.refreshChatGPTAccount() }
        guard settings.preferredProvider == provider, settings.hasCloudAccess(for: provider) else { return }
        await settings.discoverModels()
      }
    }
  }

  private func credentialButtons(
    provider: CloudProviderID,
    apiKey: Binding<String>
  ) -> some View {
    HStack {
      Button("Save to Keychain") {
        do {
          try settings.saveAPIKey(apiKey.wrappedValue, for: provider)
          apiKey.wrappedValue = ""
          formError = nil
        } catch {
          formError = error.localizedDescription
        }
      }
      .disabled(apiKey.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      Button("Remove") {
        do {
          try settings.removeAPIKey(for: provider)
          formError = nil
        } catch {
          formError = error.localizedDescription
        }
      }
      .disabled(!settings.hasAPIKey(for: provider))

      Spacer()

      Button("Test Connection") {
        Task { await settings.testConnection(to: provider) }
      }
      .disabled(
        !settings.hasAPIKey(for: provider)
          || settings.connectionState(for: provider) == .testing
      )
    }
  }

  @ViewBuilder
  private func connectionStatus(for provider: CloudProviderID) -> some View {
    switch settings.connectionState(for: provider) {
    case .idle:
      if settings.hasAPIKey(for: provider) {
        Label("API key stored in Keychain", systemImage: "key.fill")
          .foregroundStyle(.secondary)
      }
    case .testing:
      HStack {
        ProgressView()
          .controlSize(.small)
        Text("Testing connection…")
      }
      .foregroundStyle(.secondary)
    case .connected(let modelCount):
      VStack(alignment: .leading, spacing: 4) {
        Label("API reachable · Compatible chat models: \(modelCount)", systemImage: "checkmark.circle")
        Text("Model-list check only. Sending and billing were not tested.")
          .font(.caption)
      }
      .foregroundStyle(.secondary)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
  }
}


struct ThinkingStatusView: View {
  var text = "Thinking"

  var body: some View {
    HStack(spacing: 2) {
      EnigmaCoalescenceView().frame(width: 80, height: 64).accessibilityHidden(true)
      Text(text)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .overlay {
          GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
              let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 2) / 2
              LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 32)
                .offset(x: -32 + (geometry.size.width + 64) * progress)
            }
          }
          .mask(Text(text).font(.system(size: 14, weight: .medium)))
          .accessibilityHidden(true)
        }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }
}

private struct EnigmaCoalescenceView: NSViewRepresentable {
  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.setValue(false, forKey: "drawsBackground")
    view.setAccessibilityLabel("engima is thinking")
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    guard view.identifier == nil else { return }
    guard let asset = NSDataAsset(name: "EnigmaCoalescence"), let svg = String(data: asset.data, encoding: .utf8) else { return }
    view.identifier = NSUserInterfaceItemIdentifier("enigma-coalescence")
    // This indicator always animates; override the supplied SVG's still fallback.
    let motionStyle = ".ec-motion { display: inline !important; } .ec-still { display: none !important; }"
    view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width'><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}svg{width:100%;height:100%}body{pointer-events:none}\(motionStyle)</style></head><body>\(svg)</body></html>", baseURL: nil)
  }
}

private struct ThinkingComposerGlow: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
      let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 * 360
      RoundedRectangle(cornerRadius: 44)
        .stroke(AngularGradient(colors: [.green.opacity(0.1), .green.opacity(0.2), .green, .mint, .green.opacity(0.1)],
                                center: .center, angle: .degrees(angle)), lineWidth: 2)
        .shadow(color: .green.opacity(0.5), radius: 6)
    }
    .accessibilityHidden(true)
  }
}

struct SelectionContextCard: View {
  let context: ConversationContext
  var isBusy = false
  let remove: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "text.quote").foregroundStyle(NatureGlass.accent)
      VStack(alignment: .leading, spacing: 4) {
        Text(context.title).font(.caption.weight(.medium))
        Text(context.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer(minLength: 0)
      Button(action: remove) { Image(systemName: "xmark") }
        .buttonStyle(.plain).help("Remove selected text").accessibilityLabel("Remove selected text")
        .disabled(isBusy)
    }
    .padding(10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
  }
}
