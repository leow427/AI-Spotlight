import AppKit
import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

struct AppShellView: View {
  @ObservedObject var glassAppearance: GlassAppearanceSettings
  @ObservedObject private var cloudSettings: CloudSettingsModel
  @StateObject private var localChat: LocalChatViewModel
  @State private var draft = ""
  @State private var isModelImporterPresented = false
  @State private var isModePalettePresented = false
  @State private var selectedMode = ChatMode.auto
  @FocusState private var isComposerFocused: Bool

  init(
    glassAppearance: GlassAppearanceSettings,
    localEngine: any LocalModelEngine = LlamaCPPModelEngine(),
    cloudSettings: CloudSettingsModel = .shared,
    cloudProviders: CloudProviderRegistry = .live
  ) {
    self.glassAppearance = glassAppearance
    self.cloudSettings = cloudSettings
    _localChat = StateObject(
      wrappedValue: LocalChatViewModel(
        engine: localEngine,
        cloudProviders: cloudProviders
      )
    )
  }

  var body: some View {
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
                    .background(localChat.selectedSessionID == session.id ? .white.opacity(0.10) : .clear)
                }
                .buttonStyle(.plain)
              }
            }

            Divider()
              .padding(.top, 4)

            DeveloperToolsView(glassAppearance: glassAppearance)
              .padding(12)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        .navigationTitle("Recent")
      } detail: {
        VStack(spacing: 0) {
          conversation

          VStack(alignment: .trailing, spacing: 8) {
            routeStatus
            compactModeControls
            composer
          }
          .padding(20)
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
        .stroke(.white.opacity(0.14), lineWidth: 0.5)
    }
    .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in
      draft = ""
      localChat.newChat()
      isModePalettePresented = false
      isComposerFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .modePaletteRequested)) { _ in
      isModePalettePresented.toggle()
    }
    .onReceive(NotificationCenter.default.publisher(for: .panelPresented)) { _ in
      localChat.applicationBecameActive()
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
      Button {
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Add attachment")
      .disabled(true)

      TextField("Ask anything", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...5)
        .focused($isComposerFocused)
        .disabled(!canSubmit)
        .onSubmit(submitDraft)

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
      .fixedSize()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background {
      RoundedRectangle(cornerRadius: 18)
        .fill(.regularMaterial)
        .opacity(glassAppearance.isEnabled ? 1 - glassAppearance.clarity : 1)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .stroke(.white.opacity(0.16), lineWidth: 0.5)
    }
  }

  @ViewBuilder
  private var conversation: some View {
    if localChat.messages.isEmpty {
      Spacer()

      VStack(spacing: 10) {
        Image(systemName: selectedMode == .local ? "laptopcomputer" : "sparkles")
          .font(.system(size: 30, weight: .light))
          .foregroundStyle(.secondary)
        Text("How can I help?")
          .font(.title2.weight(.medium))
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
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(localChat.messages) { message in
              LocalMessageView(message: message)
                .id(message.id)
            }
          }
          .padding(24)
        }
        .onChange(of: localChat.messages) { _, messages in
          guard let lastMessage = messages.last else { return }
          proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
      }
    }
  }

  @ViewBuilder
  private var routeStatus: some View {
    switch selectedMode {
    case .local:
      HStack(spacing: 8) {
        switch localChat.state {
        case .installing:
          ProgressView()
            .controlSize(.small)
          Text("Installing local model…")
        case .downloading(let progress):
          ProgressView(value: progress.fractionCompleted)
            .frame(width: 72)
          Text("Downloading \(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))")
        case .preparing:
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
          Text("Sign in or add a \(cloudSettings.preferredProvider.displayName) API key.")
          SettingsLink { Text("Advanced Settings") }
        } else if cloudSettings.preferredModelID.isEmpty {
          Text("Choose a cloud model in Advanced Settings.")
          SettingsLink { Text("Advanced Settings") }
        } else {
          switch localChat.state {
          case .preparing:
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
          case .installing, .downloading:
            Text("Finish the local model task before using Cloud mode.")
          }
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .trailing)
    case .auto:
      Text("Auto routing arrives in checkpoint 6.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var compactModeControls: some View {
    Picker("Mode", selection: $selectedMode) {
      ForEach(ChatMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .pickerStyle(.segmented)
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
        Text("Mode & Model")
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
          .buttonStyle(.plain)
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
            Text("Auto chooses a route in checkpoint 6.")
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
          .stroke(.white.opacity(0.16), lineWidth: 0.5)
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
      false
    }
  }

  private var welcomeSubtitle: String {
    if selectedMode == .local {
      return localChat.installedModel == nil
        ? "Choose a GGUF model once, then chat completely offline."
        : "Runs on this Mac with no network requests."
    }
    if selectedMode == .cloud {
      return cloudSettings.isConfigured
        ? "Uses \(cloudSettings.preferredProvider.displayName) with a stateless request."
        : "Sign in or add a provider key, then choose a model."
    }
    return "Local-first assistance, ready when you are."
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
                model.displayName,
                systemImage: localChat.installedModel?.id == model.id ? "checkmark" : "cpu"
              )
            }
          }
        }
      }

      let installedIDs = Set(localChat.installedModels.map(\.id))
      let downloadableModels = LocalModelManifest.bundled.models.filter { !installedIDs.contains($0.id) }
      if !downloadableModels.isEmpty {
        Section("Download") {
          ForEach(downloadableModels) { model in
            Button {
              selectedMode = .local
              localChat.downloadModel(model)
            } label: {
              Text("\(model.displayName) · \(model.expectedByteCount, format: .byteCount(style: .file))")
            }
          }
        }
      }

      Divider()
      Button("Choose GGUF File…") {
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
                model.displayName,
                systemImage: cloudSettings.preferredModelID == model.id ? "checkmark" : "cloud"
              )
            }
          }
        }
      }

      Divider()
      SettingsLink {
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

  private func submitDraft() {
    guard canSubmit else { return }
    let prompt = draft
    draft = ""
    switch selectedMode {
    case .local:
      localChat.submit(prompt)
    case .cloud:
      localChat.submitCloud(
        prompt,
        provider: cloudSettings.preferredProvider,
        modelID: cloudSettings.preferredModelID
      )
    case .auto:
      break
    }
  }
}

private struct LocalMessageView: View {
  let message: ChatMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message.role == .user ? "You" : "AI Spotlight")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      if message.content.isEmpty {
        ProgressView()
          .controlSize(.small)
      } else if message.role == .assistant {
        Text(renderedMarkdown)
          .textSelection(.enabled)
      } else {
        Text(verbatim: message.content)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var renderedMarkdown: AttributedString {
    (try? AttributedString(markdown: message.content)) ?? AttributedString(message.content)
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

private struct DeveloperToolsView: View {
  @ObservedObject var glassAppearance: GlassAppearanceSettings
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 10) {
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
  @State private var appleSignInNonce: String?
  @State private var formError: String?

  init(settings: CloudSettingsModel = .shared) {
    self.settings = settings
  }

  var body: some View {
    Form {
      Section("AI Spotlight Account") {
        if !settings.isAccountSignInAvailable {
          Label(
            "Account sign-in is unavailable until this build has a backend URL.",
            systemImage: "server.rack"
          )
          .foregroundStyle(.secondary)
        } else if settings.isSignedIn {
          Label("Signed in with Apple", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)

          Button("Sign Out", role: .destructive) {
            settings.signOut()
          }

          Text("Cloud requests use AI Spotlight's provider accounts and usage allowance.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          SignInWithAppleButton(.continue) { request in
            let nonce = AppleSignInNonce.make()
            appleSignInNonce = nonce
            request.nonce = AppleSignInNonce.sha256(nonce)
          } onCompletion: { result in
            handleAppleSignIn(result)
          }
          .signInWithAppleButtonStyle(.black)
          .frame(height: 34)
          .disabled(settings.isSigningIn)

          if settings.isSigningIn {
            HStack {
              ProgressView()
                .controlSize(.small)
              Text("Signing in…")
            }
            .foregroundStyle(.secondary)
          }

          Text("Sign in without creating or pasting provider API keys.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let accountError = settings.accountError {
          Text(accountError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Section("Advanced Cloud Settings") {
        Picker("Preferred provider", selection: $settings.preferredProvider) {
          ForEach(CloudProviderID.allCases) { provider in
            Text(provider.displayName).tag(provider)
          }
        }

        if settings.models.isEmpty {
          Text("Model discovery has not returned any models. Enter a model ID manually below.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Picker("Preferred model", selection: $settings.preferredModelID) {
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

      Section("OpenAI API Key · Developer Fallback") {
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

      Section("Anthropic API Key · Developer Fallback") {
        SecureField(
          settings.hasAPIKey(for: .anthropic) ? "Replace stored API key" : "API key",
          text: $anthropicAPIKey
        )
        .textFieldStyle(.roundedBorder)

        credentialButtons(provider: .anthropic, apiKey: $anthropicAPIKey)
        connectionStatus(for: .anthropic)
      }

      if let formError {
        Text(formError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 720)
    .navigationTitle("AI Spotlight Settings")
    .task {
      await settings.loadCachedModels()
      if settings.hasCloudAccess(for: settings.preferredProvider), settings.models.isEmpty {
        await settings.discoverModels()
      }
    }
    .onChange(of: settings.preferredProvider) { _, provider in
      guard settings.hasCloudAccess(for: provider) else { return }
      Task { await settings.discoverModels() }
    }
  }

  private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
    defer { appleSignInNonce = nil }
    switch result {
    case .success(let authorization):
      guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let identityToken = credential.identityToken,
            let nonce = appleSignInNonce else {
        formError = CloudProviderError.invalidAppleCredential.localizedDescription
        return
      }
      formError = nil
      Task {
        await settings.signInWithApple(identityToken: identityToken, nonce: nonce)
      }
    case .failure(let error):
      formError = error.localizedDescription
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
      Label("Connected · \(modelCount) models available", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
  }
}
