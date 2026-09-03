import SwiftUI

struct AppShellView: View {
  @ObservedObject var glassAppearance: GlassAppearanceSettings
  @State private var draft = ""
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
          Spacer()

          VStack(spacing: 10) {
            Image(systemName: "sparkles")
              .font(.system(size: 30, weight: .light))
              .foregroundStyle(.secondary)
            Text("How can I help?")
              .font(.title2.weight(.medium))
            Text("Local-first assistance, ready when you are.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          Spacer()

          VStack(alignment: .trailing, spacing: 8) {
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
      isModePalettePresented = false
      isComposerFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .modePaletteRequested)) { _ in
      isModePalettePresented.toggle()
    }
    .onReceive(NotificationCenter.default.publisher(for: .panelPresented)) { _ in
      isComposerFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .stopStreamingRequested)) { _ in
      // Streaming is introduced in checkpoint 3; this notification is its cancellation hook.
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

        Label("Local model setup arrives in checkpoint 3", systemImage: "cpu")
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
