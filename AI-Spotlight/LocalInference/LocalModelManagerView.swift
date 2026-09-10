import SwiftUI
import UniformTypeIdentifiers

struct LocalModelChoiceCard: View {
  let assessment: LocalModelAssessment
  let role: String
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(isSelected ? NatureGlass.accent : .secondary)
          .font(.title3)
        VStack(alignment: .leading, spacing: 5) {
          Text(role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          Text(assessment.model.displayName).font(.headline)
          Text(assessment.model.summary).font(.subheadline).foregroundStyle(.secondary)
          Text("\(assessment.model.downloadByteCount, format: .byteCount(style: .file)) download · \(assessment.fit.rawValue)")
            .font(.subheadline)
          Text(assessment.performanceDescription).font(.caption).foregroundStyle(.secondary)
          Text(assessment.model.license).font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .natureSurface(radius: 16)
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(isSelected ? NatureGlass.accent.opacity(0.7) : .secondary.opacity(0.2), lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(role), \(assessment.model.displayName), \(assessment.fit.rawValue)")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

struct LocalModelOnboardingView: View {
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  @State private var selectedID: String?

  var body: some View {
    let recommendations = advisor.recommendations(installedModels: chat.installedModels)
    let selected = recommendations.assessments.first { $0.id == selectedID && $0.fit.canRun }
      ?? recommendations.recommended
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Label("Your Mac. Your AI.", systemImage: "desktopcomputer").font(.title2.weight(.semibold))
        Text("Choose one model for private text chat and screenshots. We leave room for macOS and your other apps.")
          .foregroundStyle(.secondary)
        if let hardware = advisor.hardware {
          Text("\(hardware.chip) · \(hardware.physicalMemory, format: .byteCount(style: .memory)) memory")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Text("Up to 10 choices, best suited to this Mac first; fewer appear when resources are limited.")
        .font(.caption).foregroundStyle(.secondary)
      ScrollView {
        VStack(spacing: 10) {
          ForEach(Array(recommendations.rankedChoices.enumerated()), id: \.element.id) { index, assessment in
            LocalModelChoiceCard(assessment: assessment,
              role: "\(index + 1). \(assessment.id == recommendations.recommended?.id ? "Recommended" : "Alternative")",
              isSelected: selected?.id == assessment.id) { selectedID = assessment.id }
          }
          if recommendations.rankedChoices.isEmpty {
            ContentUnavailableView("No suitable model found", systemImage: "memorychip",
              description: Text("No supported text-and-image model fits this Mac’s memory or disk budget. Review Local Models for the specific limits. Cloud is also available."))
          }
        }
        .padding(1)
        .disabled(chat.isBusy)
      }
      LocalModelOperationView(chat: chat, advisor: advisor)
      Text("One download includes the model, matching image support and runtime. Every component is verified before installation.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(chat.installedModels.isEmpty ? "Set Up Later" : "Done") { advisor.dismissOnboarding() }
          .disabled(chat.isBusy)
        Spacer()
        if let selected {
          let existing = chat.installedModels.first { $0.id == selected.id }
          let installed = existing.map { !selected.model.requiresUpdate($0) } ?? false
          Button(installed ? "Use Model" : "\(existing == nil ? "Download" : "Update") · \(ByteCountFormatter.string(fromByteCount: selected.model.downloadByteCount, countStyle: .file))") {
            if installed {
              chat.selectModel(id: selected.id)
              advisor.dismissOnboarding()
            } else {
              chat.downloadModel(selected.model)
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(chat.isBusy)
        }
      }
    }
    .padding(24)
    .frame(width: 560, height: 650)
    .naturePresentation()
    .interactiveDismissDisabled(chat.isBusy)
  }
}

struct LocalModelOperationView: View {
  @ObservedObject var chat: LocalChatViewModel
  @ObservedObject var advisor: LocalModelAdvisor

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch chat.state {
      case .downloading(let progress):
        ProgressView(value: progress.fractionCompleted)
        HStack {
          Text(progress.fractionCompleted < 1 ? "Downloading \(Int(progress.fractionCompleted * 100))%" : "Verifying and installing package…")
          Spacer()
          Button("Cancel") { chat.cancelInstallation() }
        }
      case .installing:
        ProgressView("Installing model…")
      case .deleting:
        ProgressView("Deleting model…")
      case .benchmarking:
        HStack {
          ProgressView().controlSize(.small)
          Text("Checking performance on this Mac…")
          Spacer()
          Button("Cancel") { chat.cancelInstallation() }
        }
      case .failed(let message):
        Text(message).foregroundStyle(.red)
      default:
        if let notice = chat.benchmarkNotice { Text(notice).foregroundStyle(.secondary) }
      }
      if let benchmark = advisor.latestBenchmark(for: chat.installedModel), !chat.isBusy {
        Text("First token \(benchmark.metrics.timeToFirstToken, specifier: "%.2f") s · Generation \(benchmark.metrics.generationTokensPerSecond, specifier: "%.1f") tokens/s")
        Text("Prompt \(benchmark.metrics.promptTokensPerSecond, specifier: "%.0f") tokens/s · Peak app memory \(benchmark.metrics.peakMemoryBytes, format: .byteCount(style: .memory))")
          .foregroundStyle(.secondary)
        if benchmark.underperformed,
           let faster = advisor.recommendations(installedModels: chat.installedModels).fasterAlternative(to: benchmark.modelID) {
          Text("This model ran slower than expected. For quicker replies, try \(faster.model.displayName) in the model manager.")
            .foregroundStyle(.orange)
        }
      }
      if let notice = advisor.notice { Text(notice).foregroundStyle(.secondary) }
    }
    .font(.caption)
  }
}

struct LocalModelManagerSection: View {
  @ObservedObject var advisor: LocalModelAdvisor = .shared
  @ObservedObject var chat: LocalChatViewModel = .shared
  @State private var isImporterPresented = false
  @State private var pendingDeletion: LocalModel?

  var body: some View {
    Section("Local Models") {
      let recommendations = advisor.recommendations(installedModels: chat.installedModels)
      if let hardware = advisor.hardware {
        Text("\(hardware.chip) · \(hardware.inferenceMemoryBudget, format: .byteCount(style: .memory)) available for inference")
          .font(.caption).foregroundStyle(.secondary)
      }
      if chat.state != .idle || chat.benchmarkNotice != nil || advisor.latestBenchmark(for: chat.installedModel) != nil || advisor.notice != nil {
        LocalModelOperationView(chat: chat, advisor: advisor)
      }
      Text("One selected model handles chat, screenshots and search answers. Every recommended package includes image support.")
        .font(.caption).foregroundStyle(.secondary)
      if chat.installedModel?.supportsVision == false {
        Text("Your selected model supports text and OCR only. Install a recommended package to answer visual questions. Your existing files stay available below.")
          .font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Button("Refresh Recommendations") {
          Task {
            await advisor.detectHardware()
            await advisor.refreshCatalog(force: true)
          }
        }
        Button("Check Performance") { chat.runModelBenchmark() }
          .disabled(chat.installedModel == nil)
      }
      .disabled(chat.isBusy || advisor.isDetecting)
      Text("Best choices for this Mac")
        .font(.headline)
      Text("Up to 10 compatible models, ranked by responsiveness and reviewed text/image capability. Check Performance can refine the order for your Mac.")
        .font(.caption).foregroundStyle(.secondary)
      if recommendations.rankedChoices.count < 10 {
        Text("\(recommendations.rankedChoices.count) compatible choices are available on this Mac; up to 10 are shown.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(Array(recommendations.rankedChoices.enumerated()), id: \.element.id) { index, assessment in
        modelRow(assessment, rank: index + 1, isRecommended: assessment.id == recommendations.recommended?.id)
      }
      if !recommendations.otherAssessments.isEmpty {
        DisclosureGroup("Other models and hardware limits") {
          ForEach(recommendations.otherAssessments) { assessment in
            modelRow(assessment)
          }
        }
      }
      let imported = chat.installedModels.filter { model in !advisor.manifest.models.contains { $0.id == model.id } }
      ForEach(imported) { model in
        HStack {
          VStack(alignment: .leading) {
            Text(model.displayName)
            Text(model.supportsVision ? "Legacy/imported image model · Select to use for all requests" : "Legacy/imported text-only model · OCR available, images unsupported").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button(chat.installedModel?.id == model.id ? "Selected" : "Use") { chat.selectModel(id: model.id) }
            .disabled(chat.isBusy || chat.installedModel?.id == model.id)
          deleteButton(model)
        }
      }
      LocalFileToolsSetupView(model: chat.installedModel)
      FileRecoveryMenu(files: chat.files)
      Button("Advanced: Import Text GGUF…") { isImporterPresented = true }.disabled(chat.isBusy)
      Text("Approved model catalog · Version \(advisor.manifest.version)")
        .font(.caption).foregroundStyle(.secondary)
    }
    .task {
      await chat.refreshInstalledModel()
      await advisor.start(installedModels: chat.installedModels, presentOnboarding: false)
    }
    .fileImporter(isPresented: $isImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data], allowsMultipleSelection: false) { result in
      if case .success(let urls) = result, let url = urls.first { chat.installModel(from: url) }
    }
    .alert(item: $pendingDeletion) { model in
      Alert(
        title: Text("Delete \(model.displayName)?"),
        message: Text("This removes the downloaded model and its local support files from this Mac."),
        primaryButton: .destructive(Text("Delete")) { chat.deleteModel(id: model.id) },
        secondaryButton: .cancel()
      )
    }
  }

  private func modelRow(_ assessment: LocalModelAssessment, rank: Int? = nil, isRecommended: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top) {
        Text(rank.map { "\($0). \(assessment.model.displayName)" } ?? assessment.model.displayName).font(.subheadline.weight(.medium))
        Spacer(minLength: 8)
        if let installed = chat.installedModels.first(where: { $0.id == assessment.id }) {
          if !assessment.model.requiresUpdate(installed) {
            Button(chat.installedModel?.id == assessment.id ? "Selected" : "Use") {
              chat.selectModel(id: assessment.id)
            }
            .disabled(chat.isBusy || !assessment.canInstall || chat.installedModel?.id == assessment.id)
          } else {
            Button(assessment.permitsMemoryOverride ? "Update Anyway" : "Update") { chat.downloadModel(assessment.model) }
              .disabled(chat.isBusy || !assessment.canInstall)
          }
          deleteButton(installed)
        } else {
          Button(assessment.permitsMemoryOverride ? "Install Anyway" : "Install") { chat.downloadModel(assessment.model) }
            .disabled(chat.isBusy || !assessment.canInstall)
        }
      }
      Text(assessment.model.summary).font(.subheadline).foregroundStyle(.secondary)
      Text(isRecommended ? "Recommended · \(assessment.fit.rawValue)" : assessment.fit.rawValue)
        .font(.caption.weight(.medium))
        .foregroundStyle(assessment.fit.canRun ? Color.secondary : .orange)
      Text("\(assessment.model.maker) · \(assessment.model.downloadByteCount, format: .byteCount(style: .file)) · \(assessment.model.license)")
        .font(.caption).foregroundStyle(.secondary)
      Text(assessment.performanceDescription).font(.caption).foregroundStyle(.secondary)
      if assessment.permitsMemoryOverride {
        Text("Install anyway is enabled. This model may put this Mac under memory pressure or fail to load.")
          .font(.caption).foregroundStyle(.orange)
      }
      DisclosureGroup("Model details") {
        Text("\(assessment.model.quantization) · \(assessment.model.recommendedContextSize) token context · \(assessment.model.performanceClass)")
        Text("Estimated memory \(assessment.model.estimatedRuntimeMemory, format: .byteCount(style: .memory)) · Minimum Mac memory \(assessment.model.minimumMemory, format: .byteCount(style: .memory))")
        Link("Model card and license", destination: assessment.model.downloadURL
          .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
      }
      .font(.caption)
    }
    .padding(.vertical, 5)
  }

  private func deleteButton(_ model: LocalModel) -> some View {
    Button("Delete", role: .destructive) { pendingDeletion = model }
      .disabled(chat.isBusy)
      .accessibilityLabel("Delete \(model.displayName)")
  }
}
