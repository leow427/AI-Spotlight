import SwiftUI

struct LocalModelDiscoveryView: View {
  enum Source: String, CaseIterable { case selection = "Selected models", hub = "More on Hugging Face" }
  @ObservedObject var discovery: LocalModelDiscovery
  @ObservedObject var advisor: LocalModelAdvisor = .shared
  @ObservedObject var chat: LocalChatViewModel = .shared
  @State private var searchText = ""
  @State private var query = ModelDiscoveryQuery()
  @State private var requestID = UUID()
  @State private var pageRequest: Task<Void, Never>?
  @State private var source = Source.selection
  @State private var downloadModel: HuggingFaceModelListing?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        HuggingFaceDownloadProgress()
        featuredModel
        VStack(alignment: .leading, spacing: 12) {
          Text("Discover vision & audio models").font(.headline)
          Text("A selection for visual conversation and speech, with direct downloads.")
            .font(.caption).foregroundStyle(.secondary)
          Picker("Browse", selection: $source) {
            ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented)
            .onChange(of: source) { _, _ in requestID = UUID() }
          Picker("Capability", selection: $query.scope) {
            ForEach(ModelDiscoveryScope.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          .onChange(of: query.scope) { _, _ in
            query.taskID = nil
            requestID = UUID()
          }
          HStack(spacing: 8) {
            TextField("Search models or publishers", text: $searchText)
              .textFieldStyle(.roundedBorder)
              .onSubmit(search)
              .accessibilityLabel("Search Hugging Face models")
            Button("Search", action: search)
          }
          if source == .hub {
            Picker("Task", selection: $query.taskID) {
              Text("All tasks").tag(String?.none)
              ForEach(HuggingFaceTask.tasks(for: query.scope)) { task in
                Text(task.name).tag(Optional(task.id))
              }
            }
            .onChange(of: query.taskID) { _, _ in requestID = UUID() }
          }
          Text("Enigma supports text and images. Audio models can be downloaded for use in another app.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).natureSurface(radius: 18)

        if source == .selection { selectedPackages }
        else { results }
      }
      .padding(20)
    }
    .task(id: requestID) {
      pageRequest?.cancel()
      if source == .hub { await discovery.search(query) }
    }
    .task {
      await chat.refreshInstalledModel()
      await advisor.start(installedModels: chat.installedModels, presentOnboarding: false)
    }
    .onDisappear { pageRequest?.cancel() }
    .sheet(item: $downloadModel) { model in HuggingFaceDownloadSheet(model: model) }
  }

  private func search() {
    query.search = searchText
    requestID = UUID()
  }

  private var featuredModel: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Featured · Local model", systemImage: "sparkles")
        .font(.caption.weight(.semibold)).foregroundStyle(NatureGlass.accent)
      Text("Gemma 4 26B-A4B (MoE)").font(.title3.weight(.semibold))
      Text("Q4_K_M · Vision · Google")
        .font(.subheadline.weight(.medium))
        .help("A mixture-of-experts model with about 4B active parameters. The full model still needs to fit in memory.")
      if let model = advisor.manifest.models.first(where: { $0.id == LocalModelDiscovery.featuredModelID }) {
        Text("\(model.downloadByteCount, format: .byteCount(style: .file)) download · ~\(model.advertisedMemoryRange ?? "21–25") GB RAM estimate")
          .font(.caption).foregroundStyle(.secondary)
        let assessment = advisor.recommendations(installedModels: chat.installedModels).assessments.first { $0.id == model.id }
        if assessment == nil {
          Text("Checking this Mac’s available memory and storage…").font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          featuredAction(model, assessment: assessment)
          Link("Model card", destination: URL(string: "https://huggingface.co/bartowski/google_gemma-4-26B-A4B-it-GGUF")!)
          Spacer(minLength: 0)
          Button("Local Models") {
            NotificationCenter.default.post(name: .settingsDestinationRequested, object: SettingsView.SettingsDestination.local)
          }
        }
        .controlSize(.small)
        if let assessment, !assessment.fit.canRun {
          Text(assessment.permitsMemoryOverride
            ? "Memory warning: this model may run slowly, use swap or fail to load on this Mac. You can still install it."
            : "Compatibility warning: \(assessment.reason) You can still download its files.")
            .font(.caption).foregroundStyle(.orange)
        }
      }
      if chat.isBusy || operationFailed {
        LocalModelOperationView(chat: chat, advisor: advisor)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .natureSurface(radius: 18)
    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(NatureGlass.accent.opacity(0.25)) }
  }

  private var operationFailed: Bool {
    if case .failed = chat.state { return true }
    return false
  }

  @ViewBuilder
  private func featuredAction(_ model: LocalModelDescriptor, assessment: LocalModelAssessment?) -> some View {
    let installed = chat.installedModels.first { $0.id == model.id }
    let isCurrent = installed.map { !model.requiresUpdate($0) } ?? false
    let selected = chat.installedModel?.id == model.id
    if let assessment, !assessment.canInstall {
      Button("Download Q4 files") { downloadModel = HuggingFaceModelListing(id: model.huggingFaceRepositoryID) }
    } else {
      Button(isCurrent ? (selected ? "Selected" : "Use Model") : (installed == nil ? "Install Q4_K_M" : "Update Q4_K_M")) {
        if isCurrent { chat.selectModel(id: model.id) }
        else { chat.downloadModel(model) }
      }
      .buttonStyle(.borderedProminent)
      .disabled(chat.isBusy || assessment == nil || (isCurrent && selected))
    }
  }

  @ViewBuilder
  private var selectedPackages: some View {
    let packages = advisor.recommendations(installedModels: chat.installedModels).assessments.filter {
      guard $0.id != LocalModelDiscovery.featuredModelID,
            query.scope != .audio || $0.model.modelSupportsAudio == true else { return false }
      let text = "\($0.model.displayName) \($0.model.maker) \($0.model.quantization)"
      return query.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || text.localizedCaseInsensitiveContains(query.search.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if advisor.hardware == nil {
      ProgressView("Preparing model choices…")
    } else if packages.isEmpty {
      ContentUnavailableView("No matching packages", systemImage: "magnifyingglass",
        description: Text("Try another search or explore more models on Hugging Face."))
    }
    ForEach(packages) { assessment in
      DiscoverPackageRow(assessment: assessment, chat: chat) {
        downloadModel = HuggingFaceModelListing(id: assessment.model.huggingFaceRepositoryID)
      }
    }
  }

  @ViewBuilder
  private var results: some View {
    HStack {
      Text("\(discovery.models.count) \(discovery.models.count == 1 ? "model" : "models") loaded")
        .font(.subheadline.weight(.medium))
      Spacer()
      if discovery.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Loading models") }
    }
    if !discovery.models.isEmpty {
      Text("Most downloaded among loaded results. Load more to continue through the catalog.")
        .font(.caption).foregroundStyle(.secondary)
    }
    if let notice = discovery.notice {
      VStack(alignment: .leading, spacing: 8) {
        Text(notice).font(.callout)
        if discovery.failedTaskCount > 0 {
          Text("\(discovery.failedTaskCount) task lists could not load. Available results are shown below.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button("Retry failed requests") { pageRequest = Task { await discovery.retry() } }
          .disabled(discovery.isLoading)
      }
      .padding(14).natureSurface(radius: 16)
    }
    if discovery.models.isEmpty && !discovery.isLoading && discovery.notice == nil {
      ContentUnavailableView("No matching models", systemImage: "magnifyingglass",
        description: Text("Try another model name, publisher or task."))
    }
    ForEach(discovery.models) { model in
      HuggingFaceModelRow(model: model,
        hasLocalPackage: advisor.manifest.models.contains { $0.huggingFaceRepositoryID == model.id },
        download: { downloadModel = model })
    }
    if discovery.hasMore {
      Button(discovery.isLoading ? "Loading models…" : "Load more models") {
        pageRequest = Task { await discovery.loadMore() }
      }
      .disabled(discovery.isLoading)
      .frame(maxWidth: .infinity)
    } else if !discovery.models.isEmpty && !discovery.isLoading {
      Text("You’ve reached the end of these results.").font(.caption).foregroundStyle(.secondary)
    }
    Text("Search terms are sent to Hugging Face when you search. Browsing downloads model listings only.")
      .font(.caption2).foregroundStyle(.secondary)
  }
}

struct HuggingFaceModelRow: View {
  let model: HuggingFaceModelListing
  var hasLocalPackage = false
  let download: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(model.name).font(.subheadline.weight(.semibold)).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Text(model.publisher).font(.caption).foregroundStyle(.secondary)
      Text(model.tasks.map(\.name).joined(separator: " · "))
        .font(.caption).foregroundStyle(NatureGlass.accent)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        if let downloads = model.downloads {
          Label(downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down")
            .help("Hugging Face downloads")
        }
        if let likes = model.likes {
          Label(likes.formatted(.number.notation(.compactName)), systemImage: "heart")
        }
        if model.isGGUF { Text("GGUF") }
        if let license = model.license { Text(license).lineLimit(1) }
      }
      .font(.caption2).foregroundStyle(.secondary)
      HStack {
        Button("Download files", action: download).buttonStyle(.borderedProminent)
        Link("Model card", destination: model.url)
        Spacer(minLength: 0)
        if hasLocalPackage {
          Button("See local packages") {
            NotificationCenter.default.post(name: .settingsDestinationRequested, object: SettingsView.SettingsDestination.local)
          }
        }
      }
      .font(.caption)
      Text("Compatibility warning: this model may require another runtime. Enigma does not support audio input yet.")
        .font(.caption2).foregroundStyle(.orange)
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading).natureSurface(radius: 16)
  }
}

extension LocalModelDescriptor {
  var huggingFaceRepositoryID: String {
    downloadURL.pathComponents.dropFirst().prefix(2).joined(separator: "/")
  }
}
