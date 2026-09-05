import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LocalVisionSettingsView: View {
  @ObservedObject var chat: LocalChatViewModel
  @ObservedObject var settings: ScreenSettings = .shared
  @State private var modelURL: URL?
  @State private var projectorURL: URL?
  @State private var serverURL: URL?

  var body: some View {
    Section("Image understanding") {
      Text("Give Screen a model that can see photos, colors, and layouts. Everything runs on this Mac.")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(LocalVisionModelDescriptor.bundled) { descriptor in
        let installed = chat.installedModels.first { $0.id == descriptor.id }
        let needsUpdate = installed.map(descriptor.requiresUpdate) ?? false
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .top) {
            Label(descriptor.displayName, systemImage: "eye").font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            if let model = installed, !needsUpdate,
               FileManager.default.isExecutableFile(atPath: model.visionConfiguration?.serverExecutableURL.path ?? "") {
              useButton(model)
            } else {
              Button(needsUpdate ? "Update" : "Download") {
                chat.downloadVisionModel(descriptor) { model in
                  if !needsUpdate { settings.localVisionModelID = model.id }
                }
              }
              .disabled(chat.isBusy)
              .accessibilityLabel("\(needsUpdate ? "Update" : "Download") \(descriptor.displayName) for images")
            }
          }
          if needsUpdate {
            Text("Update the installed package to fix image requests. Your model selections are preserved.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Text(descriptor.summary).font(.caption).foregroundStyle(.secondary)
          Text("\(descriptor.downloadByteCount, format: .byteCount(style: .file)) total · All required files included")
            .font(.caption).foregroundStyle(.secondary)
          Link("Model details and license", destination: descriptor.modelCardURL).font(.caption2)
          if chat.visionDownloadID == descriptor.id {
            switch chat.state {
            case .downloading(let progress):
              ProgressView(value: progress.fractionCompleted)
              HStack {
                Text(progress.fractionCompleted < 1
                  ? "Downloading \(Int(progress.fractionCompleted * 100))%"
                  : "Preparing image support…")
                Spacer()
                Button("Cancel") { chat.cancelInstallation() }
              }.font(.caption)
            case .failed(let message):
              Text(message).font(.caption).foregroundStyle(.red)
            default: EmptyView()
            }
          }
        }.padding(.vertical, 5)
      }
      Text("Downloads the model and matching image support from Hugging Face and llama.cpp. Your regular text model stays selected. These small models can make mistakes, especially on dense screenshots.")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(chat.installedModels.filter { model in
        model.supportsVision && !LocalVisionModelDescriptor.bundled.contains { $0.id == model.id }
      }) { model in
        HStack {
          Label(model.displayName + " · Vision", systemImage: "eye").font(.caption)
          Spacer()
          useButton(model)
        }
      }
      DisclosureGroup("Advanced: import your own files") {
        choose("Vision model GGUF", url: $modelURL, gguf: true)
        choose("Matching mmproj GGUF", url: $projectorURL, gguf: true)
        choose("llama-server executable", url: $serverURL, gguf: false)
        Button("Import Local Vision Model") {
          guard let modelURL, let projectorURL, let serverURL else { return }
          chat.installModel(from: modelURL, vision: LocalVisionConfiguration(projectorURL: projectorURL, serverExecutableURL: serverURL))
        }
        .disabled(chat.isBusy || modelURL == nil || projectorURL == nil || serverURL == nil)
        Text("Choose the model’s matching projector and a current llama.cpp executable. Keep the executable with its accompanying libraries in a permanent folder.")
          .font(.caption).foregroundStyle(.secondary)
      }.font(.caption)
    }
  }

  private func useButton(_ model: LocalModel) -> some View {
    let selected = settings.preferredLocalVisionModels(from: chat.installedModels).first?.id == model.id
    return Button(selected ? "Ready for Screen" : "Use for Screen") { settings.localVisionModelID = model.id }
      .disabled(chat.isBusy || selected)
      .accessibilityLabel("\(model.displayName), \(selected ? "Ready for Screen" : "Use for Screen")")
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
      }.disabled(chat.isBusy)
      Text(url.wrappedValue?.lastPathComponent ?? "Choose a file")
        .lineLimit(1).font(.caption).foregroundStyle(.secondary)
    }
  }
}
