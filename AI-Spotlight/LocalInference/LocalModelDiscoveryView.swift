import SwiftUI

struct LocalModelDiscoveryView: View {
  @ObservedObject var discovery: LocalModelDiscovery
  @ObservedObject var advisor: LocalModelAdvisor = .shared
  @ObservedObject var chat: LocalChatViewModel = .shared
  @State private var searchText = ""
  @State private var query = ModelDiscoveryQuery()
  @State private var requestID = UUID()
  @State private var pageRequest: Task<Void, Never>?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        featuredModel
        VStack(alignment: .leading, spacing: 12) {
          Text("Explore Hugging Face").font(.headline)
          Text("Public models, organized by their Hugging Face task tags.")
            .font(.caption).foregroundStyle(.secondary)
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
          Picker("Task", selection: $query.taskID) {
            Text("All tasks").tag(String?.none)
            ForEach(HuggingFaceTask.tasks(for: query.scope)) { task in
              Text(task.name).tag(Optional(task.id))
            }
          }
          .onChange(of: query.taskID) { _, _ in requestID = UUID() }
          Text("Enigma supports text and images. Explore audio models and their requirements on Hugging Face.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).natureSurface(radius: 18)

        results
      }
      .padding(20)
    }
    .task(id: requestID) {
      pageRequest?.cancel()
      await discovery.search(query)
    }
    .task {
      await chat.refreshInstalledModel()
      await advisor.start(installedModels: chat.installedModels, presentOnboarding: false)
    }
    .onDisappear { pageRequest?.cancel() }
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
        if let assessment {
          Text(assessment.fit.canRun ? assessment.fit.rawValue : "\(assessment.fit.rawValue) · \(assessment.reason)")
            .font(.caption).foregroundStyle(assessment.fit.canRun ? Color.secondary : .orange)
        } else {
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
    Button(isCurrent ? (selected ? "Selected" : "Use Model") : (installed == nil ? "Install Q4_K_M" : "Update Q4_K_M")) {
      if isCurrent { chat.selectModel(id: model.id) }
      else { chat.downloadModel(model) }
    }
    .buttonStyle(.borderedProminent)
    .disabled(chat.isBusy || assessment?.canInstall != true || (isCurrent && selected))
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
        hasLocalPackage: advisor.manifest.models.contains { $0.huggingFaceRepositoryID == model.id })
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
        Link("Open on Hugging Face", destination: model.url)
        Spacer(minLength: 0)
        if hasLocalPackage {
          Button("See local packages") {
            NotificationCenter.default.post(name: .settingsDestinationRequested, object: SettingsView.SettingsDestination.local)
          }
        }
      }
      .font(.caption)
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading).natureSurface(radius: 16)
  }
}

extension LocalModelDescriptor {
  var huggingFaceRepositoryID: String {
    downloadURL.pathComponents.dropFirst().prefix(2).joined(separator: "/")
  }
}
