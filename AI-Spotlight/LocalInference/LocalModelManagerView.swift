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
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)
          .font(.title3)
        VStack(alignment: .leading, spacing: 5) {
          Text(role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          Text(assessment.model.displayName).font(.headline)
          Text("\(assessment.model.expectedByteCount, format: .byteCount(style: .file)) download · \(assessment.fit.rawValue)")
            .font(.subheadline)
          Text(assessment.performanceDescription).font(.caption).foregroundStyle(.secondary)
          Text(assessment.model.license).font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(isSelected ? Color.accentColor.opacity(0.7) : .secondary.opacity(0.2), lineWidth: 1)
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
        Text("Choose a model for private, offline conversations. We leave room for macOS and your other apps.")
          .foregroundStyle(.secondary)
        if let hardware = advisor.hardware {
          Text("\(hardware.chip) · \(hardware.physicalMemory, format: .byteCount(style: .memory)) memory")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      ScrollView {
        VStack(spacing: 10) {
          if let recommended = recommendations.recommended {
            LocalModelChoiceCard(assessment: recommended, role: "Recommended", isSelected: selected?.id == recommended.id) {
              selectedID = recommended.id
            }
            if let faster = recommendations.faster {
              LocalModelChoiceCard(assessment: faster, role: "Faster", isSelected: selected?.id == faster.id) {
                selectedID = faster.id
              }
            }
            if let smarter = recommendations.smarter {
              LocalModelChoiceCard(assessment: smarter, role: "Smarter · Higher latency", isSelected: selected?.id == smarter.id) {
                selectedID = smarter.id
              }
            }
          } else {
            ContentUnavailableView("No responsive model found", systemImage: "memorychip",
              description: Text("Free some disk space or review the model manager in Advanced Settings. Cloud is also available."))
          }
        }
        .padding(1)
        .disabled(chat.isBusy)
      }
      LocalModelOperationView(chat: chat, advisor: advisor)
      Text("Downloads come from Hugging Face. A short performance check runs on this Mac after installation.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(chat.installedModels.isEmpty ? "Set Up Later" : "Done") { advisor.dismissOnboarding() }
          .disabled(chat.isBusy)
        Spacer()
        if let selected {
          let installed = chat.installedModels.contains { $0.id == selected.id }
          Button(installed ? "Use Model" : "Download · \(ByteCountFormatter.string(fromByteCount: selected.model.expectedByteCount, countStyle: .file))") {
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
    .background(.regularMaterial)
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
          Text("Downloading \(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))")
          Spacer()
          Button("Cancel") { chat.cancelInstallation() }
        }
      case .installing:
        ProgressView("Installing model…")
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
      ForEach(recommendations.assessments.sorted { lhs, rhs in
        if lhs.id == rhs.id { return false }
        if lhs.id == recommendations.recommended?.id { return true }
        if rhs.id == recommendations.recommended?.id { return false }
        if lhs.fit.canRun != rhs.fit.canRun { return lhs.fit.canRun }
        if lhs.isResponsive != rhs.isResponsive { return lhs.isResponsive }
        return LocalModelSelector.qualityOrder(lhs, rhs)
      }) { assessment in
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .top) {
            Text(assessment.model.displayName).font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            if chat.installedModels.contains(where: { $0.id == assessment.id }) {
              Button(chat.installedModel?.id == assessment.id ? "Selected" : "Use") {
                chat.selectModel(id: assessment.id)
              }
              .disabled(chat.isBusy || !assessment.fit.canRun || chat.installedModel?.id == assessment.id)
            } else {
              Button("Install") { chat.downloadModel(assessment.model) }
                .disabled(chat.isBusy || !assessment.fit.canRun)
            }
          }
          Text(assessment.id == recommendations.recommended?.id ? "Recommended · \(assessment.fit.rawValue)" : assessment.fit.rawValue)
            .font(.caption.weight(.medium))
            .foregroundStyle(assessment.fit.canRun ? Color.secondary : .orange)
          Text("\(assessment.model.expectedByteCount, format: .byteCount(style: .file)) · \(assessment.model.license)")
            .font(.caption).foregroundStyle(.secondary)
          Text(assessment.performanceDescription).font(.caption).foregroundStyle(.secondary)
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
      let imported = chat.installedModels.filter { model in !advisor.manifest.models.contains { $0.id == model.id } }
      ForEach(imported) { model in
        HStack {
          VStack(alignment: .leading) {
            Text(model.displayName)
            Text("Imported GGUF · Compatibility checked when loaded").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button(chat.installedModel?.id == model.id ? "Selected" : "Use") { chat.selectModel(id: model.id) }
            .disabled(chat.isBusy || chat.installedModel?.id == model.id)
        }
      }
      Button("Import GGUF File…") { isImporterPresented = true }.disabled(chat.isBusy)
      Text("Approved model catalog · Version \(advisor.manifest.version)")
        .font(.caption).foregroundStyle(.secondary)
    }
    .task {
      await chat.refreshInstalledModel()
      await advisor.start(installedModels: chat.installedModels)
    }
    .fileImporter(isPresented: $isImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data], allowsMultipleSelection: false) { result in
      if case .success(let urls) = result, let url = urls.first { chat.installModel(from: url) }
    }
  }
}
