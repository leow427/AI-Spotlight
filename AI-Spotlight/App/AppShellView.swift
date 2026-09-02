import SwiftUI

struct AppShellView: View {
  @ObservedObject var glassAppearance: GlassAppearanceSettings
  @State private var draft = ""

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

          composer
            .padding(20)
        }
      }
    }
    .frame(minWidth: 640, minHeight: 420)
    .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in
      draft = ""
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

      Picker("Model", selection: .constant("Local")) {
        Text("Local").tag("Local")
      }
      .labelsHidden()
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
