import AppKit
import Combine
import SwiftUI
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

/// A quiet botanical accent, with enough depth to stay legible in light mode.
private enum NatureGlass {
  static let accent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0.66, green: 0.86, blue: 0.72, alpha: 1)
      : NSColor(srgbRed: 0.22, green: 0.43, blue: 0.31, alpha: 1)
  })
  static let edge = LinearGradient(colors: [accent.opacity(0.5), .white.opacity(0.14), accent.opacity(0.18)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
}

private struct NatureButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(NatureGlass.accent.opacity(isEnabled && isHovered ? 0.09 : 0),
                  in: RoundedRectangle(cornerRadius: 9))
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
      .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
      .onHover { isHovered = $0 }
  }
}

struct AppShellView: View {
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

      NavigationSplitView {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if localChat.sessions.isEmpty {
              Text("No recent chats")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
            } else {
              ForEach(localChat.sessions) { session in
                Button {
                  localChat.selectSession(id: session.id)
                } label: {
                  Label(session.title, systemImage: "message")
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(localChat.selectedSessionID == session.id ? NatureGlass.accent.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 9))
                    .overlay(alignment: .leading) {
                      if localChat.selectedSessionID == session.id {
                        Capsule().fill(NatureGlass.accent).frame(width: 2, height: 16)
                      }
                    }
                }
                .buttonStyle(NatureButtonStyle())
                .padding(.horizontal, 6)
              }
            }

            Divider()
              .padding(.top, 4)

            Button {
              isHelpPresented = true
            } label: {
              Label("Help", systemImage: "questionmark.circle")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(NatureButtonStyle())
            .padding(.horizontal, 12)
            .padding(.top, 12)

            DeveloperToolsView(glassAppearance: glassAppearance, advisor: modelAdvisor, chat: localChat)
              .padding(12)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        .navigationTitle("Recent")
      } detail: {
        // The native split view measures its columns with an unconstrained
        // proposal. Wrapped composer notices must not become the panel's
        // minimum height and move its controls outside the visible window.
        GeometryReader { _ in
          VStack(spacing: 0) {
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
              if isSearchEnabled {
                HStack(spacing: 6) {
                  Text(searchSettings.hasAPIKey
                    ? "Web Search · Queries sent to Brave may include screen details."
                    : "Add a Brave Search API key to search the web.")
                  if !searchSettings.hasAPIKey {
                    Button("Settings", action: openSettings).buttonStyle(.plain)
                  }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              compactModeControls
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
              composer
            }
            .padding(20)
          }
        }
      }

      if isModePalettePresented {
        modePalette
      }
    }
    .frame(minWidth: 640, minHeight: 420)
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(NatureGlass.edge, lineWidth: 0.75)
    }
  }

  private var observedShell: some View {
    shellLayout
    .onReceive(NotificationCenter.default.publisher(for: .fileModeRequested)) { _ in
      activateFileMode(from: .keyboard)
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

  @ViewBuilder
  private var welcomeBackground: some View {
    if glassAppearance.isEnabled {
      Rectangle()
        .fill(.ultraThinMaterial)
        .opacity(1 - glassAppearance.clarity)
    } else {
      Rectangle()
        .fill(.background)
    }
  }

  private var composer: some View {
    HStack(spacing: 10) {
      HStack(spacing: 0) {
        FileModeToolButton(files: files, isBusy: localChat.isBusy) { activateFileMode(from: .menu) }
      }

      SlashCommandComposer(
        text: Binding(get: { localChat.pendingUserMessage == nil ? screen.draft : "" },
                      set: { screen.draft = $0 }),
        isFocused: Binding(get: { isComposerFocused }, set: { isComposerFocused = $0 }),
        isEnabled: !(localChat.isBusy || screen.isBusy || files.isWorking || files.isPicking),
        submit: submitDraft
      )

      Menu {
        ForEach(ChatMode.allCases) { mode in
          Button {
            selectedMode = mode
          } label: {
            Label(mode.displayName, systemImage: mode.systemImage)
          }
        }
      } label: {
        Label(selectedMode.displayName, systemImage: selectedMode.systemImage)
      }
      .menuStyle(.borderlessButton)
      .help("Mode changes apply to your next request.")
      .fixedSize()
    }
    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: isSearchPresented)
    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: screen.isPresented)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background {
      RoundedRectangle(cornerRadius: 18)
        .fill(.regularMaterial)
        .opacity(glassAppearance.isEnabled ? 1 - glassAppearance.clarity : 1)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .stroke(isComposerFocused ? NatureGlass.accent.opacity(0.55) : NatureGlass.accent.opacity(0.22),
                lineWidth: isComposerFocused ? 1 : 0.5)
    }
    .overlay {
      if localChat.activeRequest != nil { ThinkingComposerGlow().allowsHitTesting(false) }
    }
    .shadow(color: NatureGlass.accent.opacity(isComposerFocused ? 0.07 : 0), radius: 10, y: 2)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isComposerFocused)
  }

  @ViewBuilder
  private var conversation: some View {
    if localChat.presentationMessages.isEmpty && localChat.activeRequest == nil {
      Spacer()

      VStack(spacing: 10) {
        Image("SpotlightLogo")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(width: 40, height: 40)
          .accessibilityHidden(true)
          .foregroundStyle(NatureGlass.accent)
          .frame(width: 64, height: 64)
          .background(NatureGlass.accent.opacity(0.06), in: Circle())
          .overlay { Circle().stroke(NatureGlass.edge, lineWidth: 0.75) }
          .padding(.bottom, 4)
        Text("How can I help?")
          .font(.system(size: 22, weight: .medium))
        Text(welcomeSubtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        if selectedMode == .local && localChat.installedModel == nil {
          Button("Choose GGUF Model") {
            isModelImporterPresented = true
          }
          .buttonStyle(.borderedProminent)
          .disabled(localChat.isBusy)
          .padding(.top, 4)
        }
      }

      Spacer()
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          ForEach(localChat.presentationMessages) { message in
            LocalMessageView(message: message, isThinking: localChat.isWaitingForResponse && message.id == localChat.presentationMessages.last?.id)
              .id(message.id)
          }
          if localChat.isWaitingForResponse && localChat.presentationMessages.last?.role != .assistant {
            LeafThinkingView().frame(width: 64, height: 64).allowsHitTesting(false)
          }
        }
        .padding(24)
        .background(ConversationScrollObserver(contentRevision: (localChat.presentationMessages.last?.content ?? "") + String(localChat.presentationMessages.count)).allowsHitTesting(false))
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

  private var requestPhase: String {
    switch localChat.state {
    case .refiningSearch: "Preparing search query"
    case .searching: "Searching with Brave"
    case .streaming: "Streaming"
    default: "Preparing"
    }
  }

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
    Picker("Mode", selection: $selectedMode) {
      ForEach(ChatMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .help("Mode changes apply to your next request.")
    .labelsHidden()
    .controlSize(.small)
    .frame(width: 190)
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
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
      .overlay {
        RoundedRectangle(cornerRadius: 18)
          .stroke(NatureGlass.edge, lineWidth: 0.75)
      }
      .shadow(radius: 24, y: 10)
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
    let automatic = selectedMode == .auto ? AutoRouter.decide(AutoRouter.Request(
      selectedMode: .auto, webSearchEnabled: isSearchEnabled, prompt: prompt,
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
        searchEnabled: isSearchEnabled,
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
  static let body = Font.system(size: 15)
  static let label = Font.system(size: 11, weight: .semibold)
}

struct LocalMessageView: View {
  let message: ChatMessage
  var isThinking = false

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
          HStack(spacing: 6) {
            Circle().fill(NatureGlass.accent).frame(width: 5, height: 5).accessibilityHidden(true)
            Text("AI Spotlight").font(ChatTypography.label).foregroundStyle(.secondary)
          }
          if message.content.isEmpty {
            if isThinking { LeafThinkingView().frame(width: 64, height: 64).allowsHitTesting(false) }
          } else {
            Text(renderedMarkdown).font(ChatTypography.body).lineSpacing(4).textSelection(.enabled)
          }
          if let sources = message.searchSources, !sources.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
              Text("Sources · Brave Search").font(ChatTypography.label).foregroundStyle(.secondary)
              ForEach(sources) { source in
                Link(destination: source.url) {
                  Label(source.title.isEmpty ? (source.url.host ?? source.url.absoluteString) : source.title,
                        systemImage: "arrow.up.right").lineLimit(1)
                }.help(source.url.absoluteString)
              }
            }.font(.caption).padding(.top, 6)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var renderedMarkdown: AttributedString {
    (try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.content)
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
    case .auto: "sparkles"
    case .local: "laptopcomputer"
    case .cloud: "cloud"
    }
  }
}

private struct KeyboardShortcutsHelpView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("Keyboard Shortcuts", systemImage: "keyboard")
        .font(.title2.weight(.medium))

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Anywhere on your Mac")
            .font(.headline)
          shortcut("Show or hide AI Spotlight", keys: "⌥ Space")
          shortcut("Open Advanced Settings", keys: "⌥ S")

          Divider()

          Text("In the chat panel")
            .font(.headline)
          shortcut("Hide the panel", keys: "Esc")
          shortcut("New chat", keys: "⌘ N")
          shortcut("Open or close Mode & Model", keys: "⌘ K")
          shortcut("Stop the response", keys: "⌘ .")
          shortcut("Next recent chat", keys: "⌃ Tab")
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
    .background(.regularMaterial)
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

  init(settings: CloudSettingsModel = .shared) {
    self.settings = settings
  }

  var body: some View {
    TabView {
      Form {
        LocalModelManagerSection()
      }
        .formStyle(.grouped)
        .tabItem { Label("Local Models", systemImage: "desktopcomputer") }
      cloudForm
        .tabItem { Label("Cloud & Search", systemImage: "cloud") }
    }
    .padding(.top, 8)
    .frame(width: 560, height: 740)
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
    .navigationTitle("AI Spotlight Settings")
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


private struct LeafThinkingView: NSViewRepresentable {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.setValue(false, forKey: "drawsBackground")
    view.setAccessibilityLabel("AI Spotlight is thinking")
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    guard view.identifier?.rawValue != String(reduceMotion) else { return }
    view.identifier = NSUserInterfaceItemIdentifier(String(reduceMotion))
    guard let asset = NSDataAsset(name: "LeafThinking"), let svg = String(data: asset.data, encoding: .utf8) else { return }
    let reducedStyle = reduceMotion ? ".leaf-cycle,.leaf-sway,.stem-grow,.leaf-unfurl,.leaf-tilt { animation: none !important; opacity: 1; transform: none; }" : ""
    view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width'><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}svg{width:100%;height:100%}body{pointer-events:none}\(reducedStyle)</style></head><body>\(svg)</body></html>", baseURL: nil)
  }
}

private struct ThinkingComposerGlow: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
      let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 * 360
      RoundedRectangle(cornerRadius: 18)
        .stroke(AngularGradient(colors: [.green.opacity(0.1), .green.opacity(0.2), .green, .mint, .green.opacity(0.1)],
                                center: .center, angle: .degrees(angle)), lineWidth: 2)
        .shadow(color: .green.opacity(0.5), radius: 6)
    }
    .accessibilityHidden(true)
  }
}
