import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppShellView: View {
  @ObservedObject var glassAppearance: GlassAppearanceSettings
  @StateObject private var localChat: LocalChatViewModel
  @State private var draft = ""
  @State private var isModelImporterPresented = false
  @State private var isModePalettePresented = false
  @State private var selectedMode = ChatModeOption.auto
  @FocusState private var isComposerFocused: Bool

  private let recentChats = [
    "Welcome to AI Spotlight",
    "Local models",
    "Writing notes",
    "Project ideas",
    "Quick questions",
  ]

  init(
    glassAppearance: GlassAppearanceSettings,
    localEngine: any LocalModelEngine = LlamaCPPModelEngine()
  ) {
    self.glassAppearance = glassAppearance
    _localChat = StateObject(
      wrappedValue: LocalChatViewModel(engine: localEngine)
    )
  }

  var body: some View {
    ZStack {
      welcomeBackground
        .ignoresSafeArea()

      NavigationSplitView {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(recentChats, id: \.self) { title in
              Label(title, systemImage: "message")
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            localModelStatus
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
        .disabled(!canSubmitLocally)
        .onSubmit(submitDraft)

      Menu {
        ForEach(ChatModeOption.allCases) { mode in
          Button {
            selectedMode = mode
          } label: {
            Label(mode.rawValue, systemImage: mode.systemImage)
          }
        }
      } label: {
        Label(selectedMode.rawValue, systemImage: selectedMode.systemImage)
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
  private var localModelStatus: some View {
    if selectedMode == .local {
      HStack(spacing: 8) {
        switch localChat.state {
        case .installing:
          ProgressView()
            .controlSize(.small)
          Text("Installing local model…")
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
            Button("Change") {
              isModelImporterPresented = true
            }
            .buttonStyle(.plain)
          } else {
            Text("A local GGUF model is required.")
            Button("Choose Model") {
              isModelImporterPresented = true
            }
            .buttonStyle(.plain)
          }
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .trailing)
    } else {
      Text(selectedMode == .auto ? "Auto routing arrives in checkpoint 6." : "Cloud mode arrives in checkpoint 5.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var compactModeControls: some View {
    Picker("Mode", selection: $selectedMode) {
      ForEach(ChatModeOption.allCases) { mode in
        Text(mode.rawValue).tag(mode)
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

        ForEach(ChatModeOption.allCases) { mode in
          Button {
            selectedMode = mode
            isModePalettePresented = false
            isComposerFocused = true
          } label: {
            HStack(spacing: 10) {
              Image(systemName: mode.systemImage)
                .frame(width: 18)
              Text(mode.rawValue)
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

        Label(localModelPaletteLabel, systemImage: "cpu")
          .font(.caption)
          .foregroundStyle(.secondary)
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

  private var canSubmitLocally: Bool {
    selectedMode == .local && localChat.installedModel != nil && !localChat.isBusy
  }

  private var welcomeSubtitle: String {
    if selectedMode == .local {
      return localChat.installedModel == nil
        ? "Choose a GGUF model once, then chat completely offline."
        : "Runs on this Mac with no network requests."
    }
    return selectedMode == .auto
      ? "Local-first assistance, ready when you are."
      : "Cloud providers are not configured yet."
  }

  private var localModelPaletteLabel: String {
    if let model = localChat.installedModel {
      return "Local: \(model.displayName)"
    }
    return "Local model not installed"
  }

  private func submitDraft() {
    guard canSubmitLocally else { return }
    let prompt = draft
    draft = ""
    localChat.submit(prompt)
  }
}

private struct LocalMessageView: View {
  let message: LocalChatMessage

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

private enum ChatModeOption: String, CaseIterable, Identifiable {
  case auto = "Auto"
  case local = "Local"
  case cloud = "Cloud"

  var id: Self { self }

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
  var body: some View {
    Form {
      Text("Settings will be added in a later checkpoint.")
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 220)
    .navigationTitle("AI Spotlight Settings")
  }
}
