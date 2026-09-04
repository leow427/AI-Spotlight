import SwiftUI

struct WebSearchControls: View {
  @Binding var isEnabled: Bool
  var isBusy: Bool
  var openSettings: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Menu {
        Button {
          isEnabled.toggle()
        } label: {
          Label(isEnabled ? "Turn off Web Search" : "Web Search", image: "WebSearch")
        }
        .disabled(isBusy)
        Divider()
        Button("Web Search Settings…", action: openSettings)
      } label: {
        Image(systemName: "plus")
          .frame(width: 24, height: 24)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Add tools")
      .help("Add tools, including Web Search")

      Button {
        isEnabled.toggle()
      } label: {
        Image("WebSearch")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .foregroundStyle(isEnabled ? Self.activeColor : Color.secondary)
          .frame(width: 22, height: 22)
          .padding(4)
          .background(isEnabled ? Self.activeColor.opacity(0.12) : .clear,
                      in: RoundedRectangle(cornerRadius: 7))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isBusy)
      .accessibilityLabel("Web Search")
      .accessibilityValue(isEnabled ? "On" : "Off")
      .help(isEnabled ? "Web Search is on. Click to turn off." : "Search with Brave · /search")
    }
  }

  static let activeColor = Color(red: 142.0 / 255, green: 216.0 / 255, blue: 160.0 / 255)
}

struct WebSearchSettingsSection: View {
  @ObservedObject var settings: WebSearchSettings
  @State private var apiKey = ""
  @State private var error: String?

  var body: some View {
    Section("Web Search · Brave") {
      SecureField(settings.hasAPIKey ? "Replace stored Brave API key" : "Brave Search API key", text: $apiKey)
        .textFieldStyle(.roundedBorder)
      HStack {
        Button("Save Key") {
          do {
            try settings.saveAPIKey(apiKey)
            apiKey = ""
            error = nil
          } catch { self.error = error.localizedDescription }
        }
        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Remove Key", role: .destructive) {
          do {
            try settings.removeAPIKey()
            apiKey = ""
            error = nil
          } catch { self.error = error.localizedDescription }
        }
        .disabled(!settings.hasAPIKey)
        if settings.hasAPIKey {
          Label("Key saved", systemImage: "checkmark.circle")
            .foregroundStyle(.green)
        }
      }
      Text("Use a Brave Search key with LLM Context access. Stored in macOS Keychain. Brave usage is billed separately.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("Turn on the search icon, choose Web Search from +, or type /search. Search sends your current question to Brave, including in Local mode; your selected model writes the answer.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Link("Brave Search API dashboard", destination: URL(string: "https://api-dashboard.search.brave.com/")!)
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
  }
}
