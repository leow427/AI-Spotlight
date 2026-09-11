import SwiftUI

struct HuggingFaceDownloadSheet: View {
  let model: HuggingFaceModelListing
  var loadRepository: @Sendable (String) async throws -> HuggingFaceRepository = HuggingFaceRepositoryClient.load
  @ObservedObject var downloads: HuggingFaceModelDownloads = .shared
  @Environment(\.dismiss) private var dismiss
  @State private var repository: HuggingFaceRepository?
  @State private var selected: Set<String> = []
  @State private var filter = ""
  @State private var error: String?
  @State private var requestID = UUID()

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Download \(model.name)").font(.title2.weight(.semibold))
      Text(model.publisher).font(.subheadline).foregroundStyle(.secondary)
      if let repository {
        TextField("Filter files or quantizations, such as Q4", text: $filter).textFieldStyle(.roundedBorder)
        HStack {
          Button("Suggested files") { selected = repository.suggestedFiles }
          Button("Select all") { selected = Set(repository.siblings.map(\.id)) }
          Button("Clear") { selected = [] }
          Spacer()
          Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
        }.disabled(downloads.isDownloading)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(repository.siblings.filter { filter.isEmpty || $0.rfilename.localizedCaseInsensitiveContains(filter) }
              .sorted { left, right in
                if left.isWeight != right.isWeight { return left.isWeight }
                return left.rfilename < right.rfilename
              }) { file in
              Toggle(isOn: Binding(get: { selected.contains(file.id) }, set: { enabled in
                if enabled { selected.insert(file.id) } else { selected.remove(file.id) }
              })) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(file.rfilename).font(.callout).fixedSize(horizontal: false, vertical: true)
                  Text(file.size, format: .byteCount(style: .file)).font(.caption).foregroundStyle(.secondary)
                }
              }
              .toggleStyle(.checkbox)
            }
          }.padding(12)
        }
        .natureSurface(radius: 14)
        .disabled(downloads.isDownloading)
        let bytes = repository.siblings.filter { selected.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
        Button("Download \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))…") {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = true
          panel.canChooseFiles = false
          panel.canCreateDirectories = true
          panel.allowsMultipleSelection = false
          panel.prompt = "Download Here"
          panel.message = "Choose a folder for \(model.name)."
          panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
          if panel.runModal() == .OK, let directory = panel.url {
            downloads.download(repository, selected: selected, into: directory)
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(selected.isEmpty || downloads.isDownloading)
        Text("Compatibility warning: these files may need another app or runtime. Enigma’s local chat supports text and images; audio is not yet supported. Include matching image/audio components and all weight shards. Downloading files does not automatically enable the model in Enigma.")
          .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      } else if let error {
        ContentUnavailableView("Could not load model files", systemImage: "wifi.exclamationmark", description: Text(error))
        Button("Retry") { requestID = UUID() }
      } else {
        Spacer()
        ProgressView("Loading model files…").frame(maxWidth: .infinity)
        Spacer()
      }
      HuggingFaceDownloadProgress(downloads: downloads)
      HStack {
        Link("Model card and license", destination: model.url)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(24).frame(width: 620, height: 660).naturePresentation()
    .task(id: requestID) {
      error = nil
      do {
        let result = try await loadRepository(model.id)
        try Task.checkCancellation()
        repository = result
        selected = result.suggestedFiles
      } catch is CancellationError { }
      catch { self.error = error.localizedDescription }
    }
  }
}

struct HuggingFaceDownloadProgress: View {
  @ObservedObject var downloads: HuggingFaceModelDownloads = .shared

  var body: some View {
    if downloads.isDownloading {
      VStack(alignment: .leading, spacing: 6) {
        Text("Downloading \(downloads.repositoryID ?? "model")").font(.caption.weight(.medium))
        if let progress = downloads.progress {
          ProgressView(value: progress.fractionCompleted)
          Text("\(progress.receivedByteCount, format: .byteCount(style: .file)) of \(progress.expectedByteCount, format: .byteCount(style: .file))")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Text(downloads.currentFile).font(.caption).lineLimit(1).truncationMode(.middle)
          Spacer()
          Button("Cancel download") { downloads.cancel() }
        }
        Text("You can close this panel while the download continues.").font(.caption2).foregroundStyle(.secondary)
      }
    } else if let error = downloads.error {
      Text(error).font(.caption).foregroundStyle(.orange)
    } else if let folder = downloads.downloadedFolder {
      HStack {
        Label("Download complete", systemImage: "checkmark.circle")
        Spacer()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
      }.font(.caption)
    }
  }
}

struct DiscoverPackageRow: View {
  let assessment: LocalModelAssessment
  @ObservedObject var chat: LocalChatViewModel
  let downloadFiles: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(assessment.model.displayName).font(.headline)
          Text("\(assessment.model.quantization) · \(assessment.model.modelSupportsAudio == true ? "Vision + Audio" : "Vision")")
            .font(.caption).foregroundStyle(NatureGlass.accent)
        }
        Spacer()
        let existing = chat.installedModels.first { $0.id == assessment.id }
        let current = existing.map { !assessment.model.requiresUpdate($0) } ?? false
        if assessment.canInstall {
          Button(current ? (chat.installedModel?.id == assessment.id ? "Selected" : "Use")
            : (existing == nil ? "Install" : "Update")) {
            if current { chat.selectModel(id: assessment.id) }
            else { chat.downloadModel(assessment.model) }
          }
          .disabled(chat.isBusy || (current && chat.installedModel?.id == assessment.id))
        } else {
          Button("Download files", action: downloadFiles)
        }
      }
      if !assessment.fit.canRun {
        Text(assessment.permitsMemoryOverride
          ? "Memory warning: this model may run slowly, use swap or fail to load on this Mac. You can still install it."
          : "Compatibility warning: \(assessment.reason) You can still download its files.")
          .font(.caption).foregroundStyle(.orange)
      }
      if assessment.model.modelSupportsAudio == true {
        Text("Audio warning: the model supports audio, but Enigma currently accepts text and images only.")
          .font(.caption).foregroundStyle(.orange)
      }
      Text(assessment.model.summary).font(.caption).foregroundStyle(.secondary)
      Text("\(assessment.model.maker) · \(assessment.model.downloadByteCount, format: .byteCount(style: .file)) · ~\(assessment.model.advertisedMemoryRange ?? "—") GB RAM estimate")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading).natureSurface(radius: 16)
  }
}
