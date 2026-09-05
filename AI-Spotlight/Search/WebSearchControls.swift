import SwiftUI

struct WebSearchControls: View {
  @Binding var isEnabled: Bool
  @Binding var isPresented: Bool
  var isBusy: Bool
  var openSettings: () -> Void
  var captureScreen: (() -> Void)? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      Menu {
        if let captureScreen {
          Button(action: captureScreen) { ToolMenuLabel(title: "Screen", imageName: "ScreenCapture") }
            .disabled(isBusy)
        }
        Button {
          isPresented.toggle()
          isEnabled = isPresented
        } label: {
          ToolMenuLabel(title: isPresented ? "Remove Web Search" : "Web Search", imageName: "WebSearch")
        }
        .disabled(isBusy)
        Divider()
        Button("Hide Inactive Tools") {
          NotificationCenter.default.post(name: .hideInactiveToolsRequested, object: nil)
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])
        .disabled(isBusy)
        Button("Web Search Settings…", action: openSettings)
      } label: {
        Image(systemName: "plus")
          .frame(width: 24, height: 24)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Add tools")
      .help("Add tools, including Screen and Web Search")

      ZStack(alignment: .leading) {
        if isPresented {
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
          .help(isEnabled ? "Web Search is on. Click to turn off." : "Click to turn on Web Search. Hide inactive tools with ⌘⇧H.")
          .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
        }
      }
      // The text field moves with this slot; clipping keeps the popping icon
      // inside the space already reserved for it throughout the transition.
      .frame(width: isPresented ? 30 : 0, height: 30, alignment: .leading)
      .clipped()
      .padding(.leading, isPresented ? 10 : 0)
    }
    .fixedSize(horizontal: true, vertical: false)
    .onReceive(NotificationCenter.default.publisher(for: .hideInactiveToolsRequested)) { _ in
      guard !isBusy, !isEnabled else { return }
      isPresented = false
    }
  }

  static let activeColor = Color(red: 142.0 / 255, green: 216.0 / 255, blue: 160.0 / 255)
}

struct ToolMenuLabel: View {
  let title: String
  let imageName: String

  var body: some View {
    Label {
      Text(title)
    } icon: {
      Image(nsImage: Self.menuImage(named: imageName))
    }
  }

  static func menuImage(named name: String) -> NSImage {
    // Native menus use the NSImage's intrinsic size, ignoring SwiftUI frames.
    // Copy the asset so resizing the menu icon cannot change the composer icon.
    let size = NSSize(width: 16, height: 16)
    let image = (NSImage(named: name)?.copy() as? NSImage) ?? NSImage(size: size)
    image.size = size
    image.isTemplate = true
    return image
  }
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
      Text("Choose Web Search from + or type /search to add the search icon. Click it to toggle search, or remove it from +. Press ⌘⇧H to hide tools that are switched off. Search sends your current question to Brave, including in Local mode; your selected model writes the answer.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Link("Brave Search API dashboard", destination: URL(string: "https://api-dashboard.search.brave.com/")!)
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
  }
}
