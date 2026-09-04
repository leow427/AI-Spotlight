import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LocalVisionSettingsView: View {
  @ObservedObject var chat: LocalChatViewModel
  @State private var modelURL: URL?
  @State private var projectorURL: URL?
  @State private var serverURL: URL?

  var body: some View {
    Section("Local Vision · Optional") {
      Text("Import a vision model and its matching multimodal projector. Screen loads this profile only when the image is needed; your normal text model stays selected.")
        .font(.caption).foregroundStyle(.secondary)
      choose("Vision model GGUF", url: $modelURL, gguf: true)
      choose("Matching mmproj GGUF", url: $projectorURL, gguf: true)
      choose("llama-server executable", url: $serverURL, gguf: false)
      Button("Import Local Vision Model") {
        guard let modelURL, let projectorURL, let serverURL else { return }
        chat.installModel(from: modelURL, vision: LocalVisionConfiguration(projectorURL: projectorURL, serverExecutableURL: serverURL))
      }
      .disabled(chat.isBusy || modelURL == nil || projectorURL == nil || serverURL == nil)
      Text("Use a current llama.cpp build with multimodal support. Choose the model’s matching projector from the same release. Files are copied into your local model library; no screenshots are saved.")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(chat.installedModels.filter(\.supportsVision)) { model in
        Label(model.displayName + " · Vision", systemImage: "eye")
          .font(.caption)
      }
    }
  }

  private func choose(_ title: String, url: Binding<URL?>, gguf: Bool) -> some View {
    HStack {
      Button(title + "…") {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        if gguf { picker.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data] }
        picker.begin { response in
          if response == .OK { url.wrappedValue = picker.url }
        }
      }
      .disabled(chat.isBusy)
      Text(url.wrappedValue?.lastPathComponent ?? "Choose a file")
        .lineLimit(1).font(.caption).foregroundStyle(.secondary)
    }
  }
}
