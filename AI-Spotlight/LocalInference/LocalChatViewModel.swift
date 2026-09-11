import AppKit
import Combine
import Foundation

@MainActor
final class LocalChatViewModel: ObservableObject {
  static let shared = LocalChatViewModel(engine: LlamaCPPModelEngine(), modelAdvisor: .shared, searchSettings: .shared, locationProvider: LocationService.shared)

  enum State: Equatable {
    case idle
    case installing
    case deleting
    case benchmarking
    case downloading(ModelDownloadProgress)
    case preparing
    case refiningSearch
    case searching
    case streaming
    case failed(String)
  }

  struct ActiveRequest: Equatable {
    let id: UUID
    let route: Route
    let modelDisplayName: String

    var displayName: String {
      if route.mode == .local { return "Local · \(modelDisplayName)" }
      let provider = CloudProviderID(rawValue: route.providerID)?.displayName ?? route.providerID
      return "Cloud · \(provider) · \(modelDisplayName)"
    }
  }

  typealias Sleep = @Sendable (Duration) async throws -> Void

  @Published private(set) var sessions: [ChatSession]
  @Published private(set) var selectedSessionID: UUID?
  @Published private(set) var installedModel: LocalModel?
  @Published private(set) var installedModels: [LocalModel] = []
  @Published private(set) var contextNotice: String?
  @Published private(set) var activity: AssistantActivity?
  private var activityMessageID: UUID?
  @Published private(set) var activeRequest: ActiveRequest?
  @Published private(set) var autoRouteDecision: AutoRouter.Decision?
  @Published private(set) var screenRouteDecision: ScreenRoutingPolicy.Decision?
  @Published private(set) var state: State = .idle
  @Published private(set) var benchmarkNotice: String?
  private let modelAdvisor: LocalModelAdvisor?

  @Published private(set) var attachedContexts: [ConversationContext] = []
  @Published private(set) var selectionRevisions: [UUID: SelectionRevision] = [:]
  @Published private(set) var isApplyingSelection = false
  private let selectionEditingSettings: SelectionEditingSettings
  private let replaceSelection: @MainActor (String, UUID) async -> Bool
  private var selectionEditRequest: (id: UUID, contextID: UUID, automatic: Bool)?
  private var replacementTask: Task<Void, Never>?
  private var selectionSettingsObservation: AnyCancellable?
  private var temporarySessionID: UUID?
  var isTemporaryChat: Bool { selectedSessionID != nil && selectedSessionID == temporarySessionID }
  var messages: [ChatMessage] { selectedSession?.messages ?? [] }

  private var requestMessages: [ChatMessage] { messages.map { message in
    var copy = message
    // The current attachment is authoritative. Removing it also removes it from future requests.
    copy.contexts = nil
    copy.selectionEditingEnabled = false
    copy.selectionDraft = nil
    return copy
  } }

  private func contextualMessage(_ prompt: String, editing: Bool = true) -> ChatMessage {
    var message = ThinkCommand.message(prompt)
    message.contexts = attachedContexts.isEmpty ? nil : attachedContexts
    message.selectionEditingEnabled = editing && attachedContexts.contains { $0.kind == .selectedText }
    message.selectionDraft = messages.reversed().compactMap { selectionRevisions[$0.id]?.text }.first
    return message
  }

  func removeContext(id: UUID) {
    replacementTask?.cancel()
    selectionEditRequest = nil
    attachedContexts.removeAll { $0.id == id }
    SelectionContextService.shared.discardTarget()
  }

  func startTemporaryChat(context: ConversationContext?) {
    stopStreaming()
    discardTemporaryChat()
    files.restoreSelection(nil)
    contextNotice = nil
    autoRouteDecision = nil
    screenRouteDecision = nil
    let session = ChatSession(title: "Temporary chat")
    temporarySessionID = session.id
    sessions.append(session)
    selectedSessionID = session.id
    files.conversationID = session.id
    attachedContexts = context.map { [$0] } ?? []
    if case .failed = state { state = .idle }
  }

  private func discardTemporaryChat() {
    replacementTask?.cancel(); replacementTask = nil
    selectionEditRequest = nil
    selectionRevisions = [:]
    if let temporarySessionID { sessions.removeAll { $0.id == temporarySessionID } }
    temporarySessionID = nil
    attachedContexts = []
  }

  // Presentation is immediate; persistence still waits for successful preparation.
  @Published private(set) var pendingUserMessage: ChatMessage?
  @Published private(set) var hasReceivedResponse = false
  var presentationMessages: [ChatMessage] {
    guard let pendingUserMessage, !messages.contains(where: { $0.id == pendingUserMessage.id }) else { return messages }
    return messages + [pendingUserMessage]
  }
  var isWaitingForResponse: Bool { activeRequest != nil && !hasReceivedResponse }

  var selectedSession: ChatSession? {
    guard let selectedSessionID else { return nil }
    return sessions.first(where: { $0.id == selectedSessionID })
  }

  var isBusy: Bool {
    // A persistence error must not make a live request accept another submission.
    if isApplyingSelection || activeRequest != nil || generationTask != nil || installationTask != nil || files.isWorking || files.isPicking { return true }
    switch state {
    case .installing, .deleting, .downloading, .benchmarking, .preparing, .refiningSearch, .searching, .streaming: return true
    case .idle, .failed: return false
    }
  }

  let files: FileModeCoordinator
  private let fileInference: any LocalToolInference
  private let fileCodex: CodexSubscriptionClient
  private let fileCloudAvailability: WorkspaceWritePolicy.CloudCheck
  private let engine: any LocalModelEngine
  private let visionEngine: any LocalVisionServing
  private let searchSettings: WebSearchSettings?
  private let locationProvider: (any LocationProviding)?
  private var requestLocationContext: String?
  private let webSearch: any WebSearchProvider
  private let cloudProviders: CloudProviderRegistry
  private let sessionStore: ChatSessionStore
  private let idleUnloadDelay: Duration
  private let sleep: Sleep
  private var generationTask: Task<Void, Never>?
  private var installationTask: Task<Void, Never>?
  private var idleUnloadTask: Task<Void, Never>?

  init(
    engine: any LocalModelEngine,
    selectionEditingSettings: SelectionEditingSettings = .shared,
    replaceSelection: @escaping @MainActor (String, UUID) async -> Bool = { await SelectionContextService.shared.replace(with: $0, contextID: $1) },
    files: FileModeCoordinator? = nil,
    fileInference: (any LocalToolInference)? = nil,
    fileCodex: CodexSubscriptionClient = .fileMode,
    fileCloudAvailability: WorkspaceWritePolicy.CloudCheck? = nil,
    visionEngine: any LocalVisionServing = LlamaServerVisionEngine(),
    modelAdvisor: LocalModelAdvisor? = nil,
    cloudProviders: CloudProviderRegistry = .live,
    webSearch: any WebSearchProvider = BraveSearchClient(),
    searchSettings: WebSearchSettings? = nil,
    locationProvider: (any LocationProviding)? = nil,
    sessionStore: ChatSessionStore = ChatSessionStore(),
    idleUnloadDelay: Duration = .seconds(300),
    sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
  ) {
    self.selectionEditingSettings = selectionEditingSettings
    self.replaceSelection = replaceSelection
    self.engine = engine
    self.files = files ?? FileModeCoordinator()
    self.fileInference = fileInference ?? (visionEngine as? any LocalToolInference) ?? LlamaServerVisionEngine()
    self.fileCodex = fileCodex
    self.fileCloudAvailability = fileCloudAvailability ?? {
      if await ScreenConnectivity.shared.isOffline { return .unavailable(reason: "This Mac is offline.") }
      guard CodexRuntimeConfiguration.executableURL() != nil else { return .unavailable(reason: "Codex is not installed.") }
      return await fileCodex.fileEditingAvailability(preferredModelID: CloudPreferencesStore().preferredModel(for: .chatGPT))
    }
    self.visionEngine = visionEngine
    self.modelAdvisor = modelAdvisor
    self.webSearch = webSearch
    self.searchSettings = searchSettings
    self.locationProvider = locationProvider
    self.cloudProviders = cloudProviders
    self.sessionStore = sessionStore
    self.idleUnloadDelay = idleUnloadDelay
    self.sleep = sleep
    sessions = sessionStore.load()
    selectedSessionID = sessions.first?.id
    self.files.restoreSelection(selectedSession?.workspace)
    self.files.conversationID = selectedSessionID
    self.files.onSelectionChange = { [weak self] selection in
      guard let self else { return }
      let sessionID = self.ensureSelectedSession()
      self.files.conversationID = sessionID
      guard let index = self.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
      self.sessions[index].workspace = selection
      self.persistSessions()
    }
    selectionSettingsObservation = selectionEditingSettings.$automaticallyReplace.dropFirst().sink { [weak self] enabled in
      guard !enabled, let self else { return }
      self.replacementTask?.cancel()
      for id in Array(self.selectionRevisions.keys) where self.selectionRevisions[id]?.status != .sent {
        self.selectionRevisions[id]?.automatic = false
      }
    }
  }

  func refreshInstalledModel() async {
    installedModel = await engine.installedModel()
    installedModels = await engine.installedModels()
  }

  func installModel(from sourceURL: URL, vision: LocalVisionConfiguration? = nil) {
    guard !isBusy else { return }
    stopStreaming()
    installationTask?.cancel()
    idleUnloadTask?.cancel()
    state = .installing
    let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    let modelName = sourceURL.deletingPathExtension().lastPathComponent
    let accessedProjector = vision?.projectorURL.startAccessingSecurityScopedResource() ?? false
    let model = LocalModel(id: modelName.lowercased() + (vision == nil ? "" : ":vision"), displayName: modelName, fileURL: sourceURL, visionConfiguration: vision)

    installationTask = Task { [weak self, engine] in
      defer {
        if didAccessSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        if accessedProjector { vision?.projectorURL.stopAccessingSecurityScopedResource() }
      }
      do {
        await self?.visionEngine.unload()
        try await engine.install(model)
        guard let self else { return }
        await self.refreshInstalledModel()
        try Task.checkCancellation()
        if vision == nil { await self.benchmarkInstalledModel(prediction: nil) }
        self.state = .idle
        self.installationTask = nil
      } catch is CancellationError {
        self?.finishInstallation()
      } catch {
        self?.failInstallation(error)
      }
    }
  }

  func downloadModel(_ descriptor: LocalModelDescriptor) {
    guard !isBusy else { return }
    stopStreaming()
    installationTask?.cancel()
    idleUnloadTask?.cancel()
    state = .downloading(ModelDownloadProgress(receivedByteCount: 0, expectedByteCount: descriptor.downloadByteCount))
    installationTask = Task { [weak self, engine] in
      do {
        let prediction = try await self?.modelAdvisor?.confirmDownload(descriptor, installedModels: self?.installedModels ?? [])
        try Task.checkCancellation()
        await self?.visionEngine.unload()
        _ = try await engine.download(descriptor) { [weak self] progress in
          await self?.updateDownloadProgress(progress)
        }
        guard let self else { return }
        await self.refreshInstalledModel()
        try Task.checkCancellation()
        if prediction?.permitsMemoryOverride == true {
          self.benchmarkNotice = "Installed. Memory use may be high; choose Check Performance when you are ready to test it."
        } else {
          await self.benchmarkInstalledModel(prediction: prediction)
        }
        self.state = .idle
        self.installationTask = nil
      } catch is CancellationError {
        self?.finishInstallation()
      } catch {
        self?.failInstallation(error)
      }
    }
  }

  func cancelInstallation() {
    // Keep submission blocked until the downloader/benchmark acknowledges cancellation.
    installationTask?.cancel()
  }

  func runModelBenchmark() {
    guard !isBusy, let installedModel else { return }
    idleUnloadTask?.cancel()
    state = .benchmarking
    installationTask = Task { [weak self] in
      guard let self else { return }
      await modelAdvisor?.detectHardware()
      let prediction = modelAdvisor?.recommendations(installedModels: installedModels)
        .assessments.first { $0.id == installedModel.id }
      await benchmarkInstalledModel(prediction: prediction)
      finishInstallation()
    }
  }

  private func benchmarkInstalledModel(prediction: LocalModelAssessment?) async {
    guard let modelAdvisor, let model = installedModel else { return }
    state = .benchmarking
    benchmarkNotice = nil
    do {
      try Task.checkCancellation()
      if modelAdvisor.hardware == nil { await modelAdvisor.detectHardware() }
      let measured = model.supportsVision ? try await visionEngine.benchmark(model: model) : try await engine.benchmark()
      if let metrics = measured {
        try Task.checkCancellation()
        modelAdvisor.record(metrics, model: model, prediction: prediction)
        benchmarkNotice = "Performance check complete. Results are saved on this Mac."
      }
    } catch is CancellationError {
      benchmarkNotice = "Performance check cancelled. The installed model is ready to use."
    } catch {
      // An optional benchmark failure must not undo a verified installation.
      benchmarkNotice = "Model installed. Performance check: \(error.localizedDescription)"
    }
  }

  func selectModel(id: String) {
    guard !isBusy else { return }
    // Keep submission blocked until the engine and the displayed selection agree.
    state = .preparing
    Task { [weak self, engine] in
      do {
        await self?.visionEngine.unload()
        try await engine.selectModel(id: id)
        guard let self else { return }
        await self.refreshInstalledModel()
        self.state = .idle
      } catch {
        self?.state = .failed(error.localizedDescription)
      }
    }
  }

  func deleteModel(id: String) {
    guard !isBusy, installedModels.contains(where: { $0.id == id }) else { return }
    stopStreaming()
    idleUnloadTask?.cancel()
    benchmarkNotice = nil
    state = .deleting
    installationTask = Task { [weak self, engine] in
      do {
        await self?.visionEngine.unload()
        await engine.unload()
        try await engine.deleteModel(id: id)
        guard let self else { return }
        await self.refreshInstalledModel()
        self.finishInstallation()
      } catch {
        self?.failInstallation(error)
      }
    }
  }

  /// File Mode has its own explicit route. Auto stays local; a write request never causes upload.
  func submitFiles(_ prompt: String, mode: ChatMode, cloudProvider: CloudProviderID,
                   cloudModelID: String, onAccepted: @escaping @MainActor () -> Void = {}) {
    guard !isBusy, !files.isWorking, !ThinkCommand.message(prompt).content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          files.selection != nil else { return }
    let local = mode != .cloud
    if local && installedModel == nil {
      files.error = "Choose a local model, or choose Use Codex to work with these files in the cloud. Auto keeps File Mode on this Mac."
      return
    }
    if !local && cloudProvider != .chatGPT {
      files.error = "Cloud File Mode uses Codex. Choose Use Codex to continue; relevant file contents may be sent to the cloud."
      return
    }
    let model = installedModel
    let level = local ? model.map { LocalFileCapabilities.production.access(for: $0) } ?? .readOnly : .readWrite
    let fileTools: AgentFileTools
    do { fileTools = try files.begin(access: level, isLocal: local, prompt: prompt, cloudAvailability: fileCloudAvailability) }
    catch { files.error = error.localizedDescription; return }
    let route = Route(mode: local ? .local : .cloud,
      providerID: local ? "llama.cpp" : CloudProviderID.chatGPT.rawValue,
      modelID: local ? model!.id : cloudModelID, usesNetwork: !local)
    var userMessage = contextualMessage(prompt)
    userMessage.attachments = files.selection?.attachments.map { MessageAttachment(name: $0.name, isDirectory: $0.isDirectory) }
    let history = requestMessages + [userMessage]
    let active = beginGeneration(route: route, modelDisplayName: local ? model!.displayName : cloudModelID)
    let sessionID = ensureSelectedSession()
    let responseID = UUID()
    state = .preparing
    contextNotice = nil
    autoRouteDecision = nil
    screenRouteDecision = nil
    append(history.last!, to: sessionID)
    files.consumeSelection(for: fileTools.workspace)
    append(ChatMessage(id: responseID, role: .assistant, content: ""), to: sessionID)
    generationTask = Task { [weak self, fileInference, fileCodex, engine, files] in
      var failure: Error?
      do {
        try Task.checkCancellation()
        self?.receiveActivity(.phase(.thinking), requestID: active.id)
        if local, let model {
          // The inference-only bridge releases its model before the tool-capable runtime loads it.
          await engine.unload()
          let owner = self
          try await LocalFileAgent(inference: fileInference).run(messages: history.map(ConversationContextPrompt.expand), model: model, tools: fileTools) { text in
            await owner?.appendFileText(text, messageID: responseID, sessionID: sessionID, requestID: active.id)
          }
        } else {
          let request = ChatRequest(sessionID: sessionID, messages: history.map(ConversationContextPrompt.expand), route: route)
          for try await event in fileCodex.stream(request, fileTools: fileTools) {
            try Task.checkCancellation()
            if case .activity(let update) = event { self?.receiveActivity(update, requestID: active.id) }
            if case .token(let text) = event {
              self?.appendFileText(text, messageID: responseID, sessionID: sessionID, requestID: active.id)
            }
          }
        }
        try Task.checkCancellation()
      } catch is CancellationError { }
      catch { failure = error }
      // Finish closes the authority before enabling the composer, including Stop and late events.
      if local { await fileInference.unload() }
      await files.finish(workspace: fileTools.workspace)
      if let failure, self?.activeRequest?.id == active.id { files.error = failure.localizedDescription }
      await self?.finishGeneration(id: active.id, error: failure)
    }
    onAccepted()
  }

  private func appendFileText(_ text: String, messageID: UUID, sessionID: UUID, requestID: UUID) {
    guard activeRequest?.id == requestID else { return }
    state = .streaming
    append(text, to: messageID, in: sessionID)
  }

  func shouldSearch(_ prompt: String, explicitlyEnabled: Bool) -> Bool {
    explicitlyEnabled || (searchSettings?.canSearchAutomatically == true
      && WebSearchPolicy.needsFreshInformation(ConversationContextPrompt.expand(contextualMessage(prompt, editing: false)).content))
  }

  func submit(_ prompt: String, searchEnabled: Bool = false, onAccepted: @escaping @MainActor () -> Void = {}) {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ThinkCommand.message(trimmedPrompt).content.isEmpty, !isBusy else { return }
    let searchEnabled = shouldSearch(trimmedPrompt, explicitlyEnabled: searchEnabled)
    if let model = installedModel, model.supportsVision {
      submitScreen(trimmedPrompt, attachment: nil, decision: .text(model.screenModel), selectedMode: .local,
                   searchEnabled: searchEnabled, cloudUploadAllowed: { false }, onAccepted: onAccepted)
      return
    }
    screenRouteDecision = nil
    idleUnloadTask?.cancel()
    let responseID = UUID()
    let userMessage = contextualMessage(trimmedPrompt)
    let request = LocalModelRequest(messages: requestMessages + [userMessage])
    let active = beginGeneration(
      route: Route(mode: .local, providerID: "local", modelID: installedModel?.id ?? "", usesNetwork: searchEnabled),
      modelDisplayName: installedModel?.displayName ?? "Local model"
    )
    contextNotice = nil
    state = .preparing
    pendingUserMessage = userMessage

    generationTask = Task { [weak self, engine] in
      do {
        try Task.checkCancellation()
        let model = await engine.installedModel()
        try Task.checkCancellation()
        guard let owner = self, owner.activeRequest?.id == active.id else { return }
        guard let model else { throw LocalInferenceError.noModelInstalled }
        // Resolve the engine's selection before preparation, including when the
        // initial model-library refresh has not finished yet.
        owner.activeRequest = ActiveRequest(
          id: active.id,
          route: Route(mode: .local, providerID: "local", modelID: model.id, usesNetwork: searchEnabled),
          modelDisplayName: model.displayName
        )
        var prepared = try await engine.prepare(request)
        var sources: [WebSearchSource]?
        if searchEnabled {
          try Task.checkCancellation()
          guard owner.activeRequest?.id == active.id else { return }
          owner.state = .searching
          let results = try await owner.search(trimmedPrompt, maximumTokens: BraveSearchClient.evidenceTokens, requestID: active.id)
          try Task.checkCancellation()
          guard owner.activeRequest?.id == active.id else { return }
          owner.state = .preparing
          let grounded = try await WebSearchContext.prepare(messages: owner.locationGrounded(request.messages), results: results) {
            try await engine.prepare(LocalModelRequest(messages: $0))
          }
          prepared = grounded.prepared
          sources = grounded.sources
          owner.receiveActivity(.sourcesSelected(grounded.sources), requestID: active.id)
        }
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        let sessionID = owner.ensureSelectedSession()
        owner.contextNotice = prepared.notice
        owner.append(userMessage, to: sessionID)
        owner.append(ChatMessage(id: responseID, role: .assistant, content: "", searchSources: sources), to: sessionID)
        onAccepted()
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        let boundedRequest = LocalModelRequest(
          messages: prepared.messages,
          maximumTokenCount: request.maximumTokenCount,
          temperature: request.temperature
        )
        owner.receiveActivity(.phase(.thinking), requestID: active.id)
        for try await fragment in engine.stream(boundedRequest) {
          try Task.checkCancellation()
          guard let self, self.activeRequest?.id == active.id else { return }
          self.state = .streaming
          self.append(fragment, to: responseID, in: sessionID)
        }
        try Task.checkCancellation()
        await self?.finishGeneration(id: active.id)
      } catch is CancellationError {
        await self?.finishGeneration(id: active.id)
      } catch {
        await self?.finishGeneration(id: active.id, error: error)
      }
    }
  }

  func submitScreen(
    _ prompt: String,
    attachment: ScreenAttachment?,
    decision: ScreenRoutingPolicy.Decision,
    selectedMode: ChatMode,
    searchEnabled: Bool = false,
    cloudUploadAllowed: @escaping @MainActor () -> Bool,
    onAccepted: @escaping @MainActor () -> Void = {}
  ) {
    let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ThinkCommand.message(prompt).content.isEmpty, !isBusy, let model = decision.model else { return }
    let searchEnabled = shouldSearch(prompt, explicitlyEnabled: searchEnabled)
    guard selectedMode != .local || model.isLocal else {
      state = .failed(ScreenRequestError.cloudUploadNotAllowed.localizedDescription)
      return
    }
    if decision.sendsImage && !model.canUseVision {
      state = .failed(ScreenRequestError.textOnlyModel.localizedDescription)
      return
    }
    let userMessage = contextualMessage(prompt)
    let preferOCR = attachment.map {
      ScreenRoutingPolicy.hasConfidentTextForLookup(prompt: prompt,
        ocr: ScreenOCRResult(text: $0.ocrText, confidence: $0.ocrConfidence))
    } ?? false
    let requestText = attachment.map { ScreenPromptContext.text(userPrompt: userMessage.content, ocr: $0.ocrText, preferOCR: preferOCR) } ?? userMessage.content
    var current = userMessage
    current.content = requestText
    let history = requestMessages + [current]
    let pixels = decision.sendsImage ? attachment?.originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
    if decision.sendsImage && pixels == nil { state = .failed(ScreenCaptureError.invalidImage.localizedDescription); return }
    idleUnloadTask?.cancel()
    let active = beginGeneration(route: model.route(searchEnabled: searchEnabled), modelDisplayName: model.id)
    state = .preparing
    contextNotice = nil
    screenRouteDecision = attachment == nil ? nil : decision
    var pending = userMessage
    pending.imagePreview = attachment?.makeMessagePreview()
    pendingUserMessage = pending
    generationTask = Task { [weak self, engine] in
      guard let owner = self else { return }
      var acceptedSession: UUID?
      let responseID = UUID()
      do {
        let image: PreparedScreenImage?
        if let pixels {
          image = try await Task.detached(priority: .userInitiated) { try ScreenImagePreprocessor.prepare(pixels) }.value
        } else { image = nil }
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        var target = model
        let requestImage = image
        var requestHistory = history
        var searchQuery: String?
        // Reuse retrieved evidence if an offline cloud attempt falls back to local vision.
        var searchResults: [WebSearchResult]?
        while true {
          do {
            let route = target.route(searchEnabled: searchEnabled)
            let prepare: ([ChatMessage], PreparedScreenImage?) async throws -> PreparedConversation
            let localModel: LocalModel?
            if target.isLocal {
              let installed = await engine.installedModels()
              try Task.checkCancellation()
              guard let installedModel = installed.first(where: { $0.id == target.id }) else { throw LocalInferenceError.noModelInstalled }
              guard await engine.installedModel()?.id == target.id else {
                throw LocalInferenceError.bridgeFailure("The selected local model changed. Please send your draft again.")
              }
              localModel = installedModel
              if installedModel.supportsVision {
                try LocalVisionModelValidation.validate(installedModel)
                await engine.unload()
                try Task.checkCancellation()
                guard owner.activeRequest?.id == active.id else { return }
                prepare = { try await owner.visionEngine.prepare(messages: $0, image: $1, model: installedModel) }
              } else {
                guard requestImage == nil else { throw ScreenRequestError.textOnlyModel }
                guard await engine.installedModel()?.id == target.id else {
                  throw LocalInferenceError.bridgeFailure("The selected local model changed. Please send your draft again.")
                }
                prepare = { messages, _ in try await engine.prepare(LocalModelRequest(messages: messages)) }
              }
            } else {
              localModel = nil
              guard CloudProviderID(rawValue: target.provider) != nil else { throw CloudProviderError.invalidResponse }
              let request = ChatRequest(sessionID: owner.selectedSessionID ?? UUID(), messages: history,
                                        route: route, image: requestImage, allowsCloudImages: requestImage != nil && cloudUploadAllowed())
              try ScreenRequestGuard.validateCloud(request)
              prepare = { messages, image in
                try CloudContext.prepare(ChatRequest(sessionID: request.sessionID, messages: messages,
                  route: route, image: image, allowsCloudImages: request.allowsCloudImages))
              }
            }
            // Validate the full question and screenshot budget before contacting Brave.
            var prepared = try await prepare(requestHistory, requestImage)
            var sources: [WebSearchSource]?
            if searchEnabled {
              try Task.checkCancellation()
              guard owner.activeRequest?.id == active.id else { return }
              if searchResults == nil {
                if let attachment, searchQuery == nil {
                  owner.activeRequest = ActiveRequest(id: active.id, route: route, modelDisplayName: target.id)
                  owner.state = .refiningSearch
                  owner.receiveActivity(.phase(.refiningSearch), requestID: active.id)
                  let queryRequest = [ChatMessage(role: .user, content:
                    ScreenSearchContext.queryPrompt(question: prompt, facts: "", ocr: attachment.ocrText))]
                  let queryContext = try await prepare(queryRequest, requestImage)
                  let queryStream = try await owner.screenOutput(queryContext, image: requestImage,
                    target: target, localModel: localModel, activeID: active.id, cloudUploadAllowed: cloudUploadAllowed,
                    temperature: 0)
                  searchQuery = try ScreenSearchContext.query(from:
                    await ScreenSearchContext.collect(queryStream, maximumBytes: 1_024))
                }
                try Task.checkCancellation()
                guard owner.activeRequest?.id == active.id else { return }
                if requestImage != nil && !target.isLocal && !cloudUploadAllowed() {
                  throw ScreenRequestError.cloudUploadNotAllowed
                }
                owner.state = .searching
                // Screen queries resolve the user's references with relevant observed facts.
                // Pixels, raw OCR, and conversation history are never attached to Brave.
                searchResults = try await owner.search(searchQuery ?? prompt, locationPrompt: prompt, maximumTokens: BraveSearchClient.evidenceTokens, requestID: active.id)
              }
              try Task.checkCancellation()
              guard owner.activeRequest?.id == active.id else { return }
              owner.state = .preparing
              if let attachment, let searchQuery {
                requestHistory[requestHistory.count - 1].content = ScreenPromptContext.text(userPrompt: prompt,
                  ocr: attachment.ocrText, preferOCR: preferOCR)
                  + "\n\nSearch query used to retrieve the evidence: " + searchQuery
              }
              let grounded = try await WebSearchContext.prepare(messages: owner.locationGrounded(requestHistory), results: searchResults!) {
                try await prepare($0, requestImage)
              }
              prepared = grounded.prepared
              sources = grounded.sources
              owner.receiveActivity(.sourcesSelected(grounded.sources), requestID: active.id)
            }
            try Task.checkCancellation()
            guard owner.activeRequest?.id == active.id else { return }
            owner.receiveActivity(.phase(.thinking), requestID: active.id)
            let output = try await owner.screenOutput(prepared, image: requestImage, target: target,
              localModel: localModel, activeID: active.id, cloudUploadAllowed: cloudUploadAllowed,
              temperature: searchEnabled ? 0.2 : 0.7)
            owner.contextNotice = prepared.notice
            owner.activeRequest = ActiveRequest(id: active.id, route: route, modelDisplayName: target.id)
            for try await fragment in output {
              try Task.checkCancellation()
              guard owner.activeRequest?.id == active.id else { return }
              guard !fragment.isEmpty else { continue }
              if acceptedSession == nil {
                let session = owner.ensureSelectedSession()
                acceptedSession = session
                // The preview is UI-only; persistence still saves just the user's question.
                var displayedMessage = userMessage
                displayedMessage.imagePreview = attachment?.makeMessagePreview()
                owner.append(displayedMessage, to: session)
                owner.append(ChatMessage(id: responseID, role: .assistant, content: "", searchSources: sources), to: session)
                onAccepted()
                try Task.checkCancellation()
                guard owner.activeRequest?.id == active.id else { return }
              }
              owner.state = .streaming
              owner.append(fragment, to: responseID, in: acceptedSession!)
            }
            guard acceptedSession != nil else { throw CloudProviderError.streamEndedUnexpectedly }
            break
          } catch {
            // A genuinely offline cloud attempt can fall back before any reply is accepted.
            if !target.isLocal, requestImage != nil, acceptedSession == nil,
               normalizedCloudError(error) as? CloudProviderError == .offline,
               let fallback = await engine.installedModel(), fallback.supportsVision, selectedMode == .auto {
              try Task.checkCancellation()
              target = fallback.screenModel
              owner.screenRouteDecision = .vision(target)
              continue
            }
            throw error
          }
        }
        await owner.finishGeneration(id: active.id)
      } catch is CancellationError {
        await owner.finishGeneration(id: active.id)
      } catch {
        await owner.finishGeneration(id: active.id, error: error)
      }
    }
  }

  private func screenOutput(
    _ prepared: PreparedConversation, image: PreparedScreenImage?, target: ScreenModel,
    localModel: LocalModel?, activeID: UUID, cloudUploadAllowed: @MainActor () -> Bool,
    temperature: Float = 0.7
  ) async throws -> AsyncThrowingStream<String, Error> {
    try Task.checkCancellation()
    guard activeRequest?.id == activeID else { throw CancellationError() }
    if let localModel {
      if localModel.supportsVision {
        // The embedded engine was released before loading the tokenizer for preparation.
        return visionEngine.stream(messages: prepared.messages, image: image, model: localModel, temperature: temperature)
      }
      guard await engine.installedModel()?.id == target.id else {
        throw LocalInferenceError.bridgeFailure("The selected local model changed. Please send your draft again.")
      }
      try Task.checkCancellation()
      guard activeRequest?.id == activeID else { throw CancellationError() }
      return engine.stream(LocalModelRequest(messages: prepared.messages, temperature: temperature))
    }
    guard let providerID = CloudProviderID(rawValue: target.provider) else { throw CloudProviderError.invalidResponse }
    let request = ChatRequest(sessionID: selectedSessionID ?? UUID(), messages: prepared.messages,
      route: target.route, image: image, allowsCloudImages: image != nil && cloudUploadAllowed())
    // Recheck consent at every image-bearing stage, including after search.
    try ScreenRequestGuard.validateCloud(request)
    return cloudProviders.provider(for: providerID).textStream(request) { [weak self] event in
      await self?.receiveActivity(event, requestID: activeID)
    }
  }

  func submitCloud(
    _ prompt: String,
    provider providerID: CloudProviderID,
    modelID: String,
    searchEnabled: Bool = false,
    onAccepted: @escaping @MainActor () -> Void = {}
  ) {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let searchEnabled = shouldSearch(trimmedPrompt, explicitlyEnabled: searchEnabled)
    screenRouteDecision = nil
    guard !ThinkCommand.message(trimmedPrompt).content.isEmpty, !trimmedModelID.isEmpty, !isBusy else { return }
    idleUnloadTask?.cancel()
    let route = Route(
      mode: .cloud,
      providerID: providerID.rawValue,
      modelID: trimmedModelID,
      usesNetwork: true
    )
    let userMessage = contextualMessage(trimmedPrompt)
    let prepared: PreparedConversation
    contextNotice = nil
    do {
      prepared = try CloudContext.prepare(ChatRequest(
        sessionID: selectedSessionID ?? UUID(), messages: requestMessages + [userMessage], route: route
      ))
    } catch {
      state = .failed(error.localizedDescription)
      return
    }
    if searchEnabled {
      submitCloudWithSearch(
        userMessage, route: route, onAccepted: onAccepted
      )
      return
    }
    let sessionID = ensureSelectedSession()
    let responseID = UUID()
    let active = beginGeneration(route: route, modelDisplayName: trimmedModelID)
    append(userMessage, to: sessionID)
    append(ChatMessage(id: responseID, role: .assistant, content: ""), to: sessionID)
    contextNotice = prepared.notice
    state = .preparing
    let provider = cloudProviders.provider(for: providerID)
    let request = ChatRequest(sessionID: sessionID, messages: prepared.messages, route: route)
    generationTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        guard self?.activeRequest?.id == active.id else { return }
        self?.receiveActivity(.phase(.thinking), requestID: active.id)
        for try await event in provider.stream(request) {
          try Task.checkCancellation()
          guard let self, self.activeRequest?.id == active.id else { return }
          switch event {
          case .activity(let update):
            self.receiveActivity(update, requestID: active.id)
          case .token(let fragment):
            self.state = .streaming
            self.append(fragment, to: responseID, in: sessionID)
          case .completed:
            break
          }
        }
        try Task.checkCancellation()
        await self?.finishGeneration(id: active.id)
      } catch is CancellationError {
        await self?.finishGeneration(id: active.id)
      } catch {
        await self?.finishGeneration(id: active.id, error: error)
      }
    }
    // Install the handle before calling out: acceptance may synchronously Stop or start a new chat.
    onAccepted()
  }

  private func submitCloudWithSearch(
    _ userMessage: ChatMessage, route: Route, onAccepted: @escaping @MainActor () -> Void
  ) {
    let history = requestMessages + [userMessage]
    let active = beginGeneration(route: route, modelDisplayName: route.modelID)
    state = .searching
    pendingUserMessage = userMessage
    generationTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        guard let owner = self, owner.activeRequest?.id == active.id else { return }
        let results = try await owner.search(userMessage.content, maximumTokens: BraveSearchClient.evidenceTokens, requestID: active.id)
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        let grounded = try await WebSearchContext.prepare(messages: owner.locationGrounded(history), results: results) {
          try CloudContext.prepare(ChatRequest(sessionID: UUID(), messages: $0, route: route))
        }
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id,
              let providerID = CloudProviderID(rawValue: route.providerID) else { return }
        let sessionID = owner.ensureSelectedSession()
        let responseID = UUID()
        owner.receiveActivity(.sourcesSelected(grounded.sources), requestID: active.id)
        owner.contextNotice = grounded.prepared.notice
        owner.state = .preparing
        owner.append(userMessage, to: sessionID)
        owner.append(ChatMessage(id: responseID, role: .assistant, content: "", searchSources: grounded.sources), to: sessionID)
        onAccepted()
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        let request = ChatRequest(sessionID: sessionID, messages: grounded.prepared.messages, route: route)
        let provider = owner.cloudProviders.provider(for: providerID)
        self?.receiveActivity(.phase(.thinking), requestID: active.id)
        for try await event in provider.stream(request) {
          try Task.checkCancellation()
          guard owner.activeRequest?.id == active.id else { return }
          if case .activity(let update) = event { owner.receiveActivity(update, requestID: active.id) }
          if case .token(let fragment) = event {
            owner.state = .streaming
            owner.append(fragment, to: responseID, in: sessionID)
          }
        }
        try Task.checkCancellation()
        await owner.finishGeneration(id: active.id)
      } catch is CancellationError {
        await self?.finishGeneration(id: active.id)
      } catch {
        await self?.finishGeneration(id: active.id, error: error)
      }
    }
  }

  func submitAuto(
    _ prompt: String,
    cloud: AutoRouter.CloudConfiguration?,
    searchEnabled: Bool = false,
    onAccepted: @escaping @MainActor () -> Void = {}
  ) {
    guard !isBusy, !ThinkCommand.message(prompt).content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    state = .idle
    contextNotice = nil
    let searchEnabled = shouldSearch(prompt, explicitlyEnabled: searchEnabled)
    let decision = (searchEnabled || AutoRouter.shouldRun(for: .auto, cloud: cloud))
      ? AutoRouter.decide(AutoRouter.Request(
        selectedMode: .auto, webSearchEnabled: searchEnabled,
        prompt: ConversationContextPrompt.expand(contextualMessage(prompt, editing: false)).content, contextMessages: requestMessages,
        localModel: installedModel, cloud: cloud
      ))
      : AutoRouter.localFallback(localModel: installedModel)
    autoRouteDecision = decision
    guard let route = decision.route else { return }
    switch route.mode {
    case .local:
      submit(prompt, searchEnabled: searchEnabled, onAccepted: onAccepted)
    case .cloud:
      guard let provider = CloudProviderID(rawValue: route.providerID) else { return }
      submitCloud(prompt, provider: provider, modelID: route.modelID, searchEnabled: searchEnabled, onAccepted: onAccepted)
    case .auto:
      break
    }
  }

  func clearAutoRouteDecision() {
    autoRouteDecision = nil
  }

  /// The returned consumer task can be awaited to observe its shutdown.
  @discardableResult
  func stopStreaming() -> Task<Void, Never>? {
    guard let task = generationTask else { return nil }
    files.revoke()
    if let id = activeRequest?.id { receiveActivity(.phase(.cancelled), requestID: id) }
    // Revoke ownership before cancellation can release any queued events or cleanup.
    activeRequest = nil
    activity = nil
    activityMessageID = nil
    pendingUserMessage = nil
    generationTask = nil
    state = .idle
    task.cancel()
    return task
  }

  func newChat() {
    stopStreaming()
    discardTemporaryChat()
    SelectionContextService.shared.discardTarget()
    files.restoreSelection(nil)
    contextNotice = nil
    autoRouteDecision = nil
    screenRouteDecision = nil
    let session = ChatSession()
    sessions.append(session)
    selectedSessionID = session.id
    files.conversationID = session.id
    sortAndPersistSessions()
    if case .failed = state { state = .idle }
  }

  func selectSession(id: UUID) {
    guard sessions.contains(where: { $0.id == id }), !isBusy else { return }
    if id != temporarySessionID { discardTemporaryChat(); SelectionContextService.shared.discardTarget() }
    selectedSessionID = id
    files.restoreSelection(selectedSession?.workspace)
    files.conversationID = selectedSessionID
    contextNotice = nil
  }

  func cycleRecentChat() {
    guard !isBusy, !sessions.isEmpty else { return }
    contextNotice = nil
    let selectedIndex = selectedSessionID.flatMap { id in sessions.firstIndex(where: { $0.id == id }) }
    let nextID = sessions[selectedIndex.map { ($0 + 1) % sessions.count } ?? 0].id
    if nextID != temporarySessionID { discardTemporaryChat(); SelectionContextService.shared.discardTarget() }
    selectedSessionID = nextID
    files.restoreSelection(selectedSession?.workspace)
    files.conversationID = selectedSessionID
  }

  func applicationBecameActive() {
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
  }

  func applicationBecameInactive() {
    idleUnloadTask?.cancel()
    idleUnloadTask = Task { [weak self, engine, visionEngine, idleUnloadDelay, sleep] in
      do {
        try await sleep(idleUnloadDelay)
        try Task.checkCancellation()
        guard self?.isBusy == false else { return }
        await engine.unload()
        await visionEngine.unload()
      } catch {
        // Cancellation means the app became active before the idle policy elapsed.
      }
    }
  }

  private func ensureSelectedSession() -> UUID {
    if let selectedSessionID { return selectedSessionID }
    let session = ChatSession()
    sessions.append(session)
    selectedSessionID = session.id
    persistSessions()
    return session.id
  }

  private func append(_ message: ChatMessage, to sessionID: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
    var message = message
    if message.role == .assistant, activeRequest != nil {
      activityMessageID = message.id
      message.activity = activity
    }
    sessions[index].append(message)
    if pendingUserMessage?.id == message.id { pendingUserMessage = nil }
    sortAndPersistSessions()
  }

  private func append(_ fragment: String, to messageID: UUID, in sessionID: UUID) {
    guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
    if !fragment.isEmpty {
      hasReceivedResponse = true
      if let id = activeRequest?.id { receiveActivity(.phase(.generating), requestID: id) }
    }
    sessions[sessionIndex].messages[messageIndex].content.append(fragment)
    sessions[sessionIndex].lastActivityAt = .now
    sortAndPersistSessions()
  }

  private func sortAndPersistSessions() {
    sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
    let retained = Set(sessions.filter { $0.id != temporarySessionID }
      .prefix(ChatSessionStore.maximumRetainedSessions).map(\.id))
    sessions.removeAll { $0.id != temporarySessionID && !retained.contains($0.id) }
    persistSessions()
  }

  private func persistSessions() {
    guard !isTemporaryChat else { return }
    do { try sessionStore.save(sessions.filter { $0.id != temporarySessionID }) }
    catch { state = .failed("Unable to save chats: \(error.localizedDescription)") }
  }

  private func finishInstallation() {
    state = .idle
    installationTask = nil
  }

  private func updateDownloadProgress(_ progress: ModelDownloadProgress) {
    guard !Task.isCancelled else { return }
    state = .downloading(progress)
  }

  private func failInstallation(_ error: Error) {
    if Task.isCancelled { finishInstallation(); return }
    state = .failed(error.localizedDescription)
    installationTask = nil
  }

  private func search(_ query: String, locationPrompt: String? = nil, maximumTokens: Int, requestID: UUID) async throws -> [WebSearchResult] {
    receiveActivity(.phase(.searching), requestID: requestID)
    var contextualQuery = query
    if !attachedContexts.isEmpty, let active = activeRequest, active.id == requestID {
      state = .refiningSearch
      receiveActivity(.phase(.refiningSearch), requestID: requestID)
      var message = ChatMessage(role: .user, content:
        "Create one concise web search query that helps answer the user's question about the attached context. "
        + "Return only the query, without quotes or commentary. Question: " + query)
      message.contexts = attachedContexts
      if let draft = messages.reversed().compactMap({ selectionRevisions[$0.id]?.text }).first {
        message.contexts?.append(ConversationContext(sourceName: "Proposed revision", text: draft))
      }
      let prepared: PreparedConversation
      let stream: AsyncThrowingStream<String, Error>
      if active.route.mode == .local {
        guard let model = await engine.installedModel() else { throw LocalInferenceError.noModelInstalled }
        if model.supportsVision {
          prepared = try await visionEngine.prepare(messages: [message], image: nil, model: model)
          stream = visionEngine.stream(messages: prepared.messages, image: nil, model: model, temperature: 0)
        } else {
          prepared = try await engine.prepare(LocalModelRequest(messages: [message]))
          stream = engine.stream(LocalModelRequest(messages: prepared.messages, maximumTokenCount: 128, temperature: 0))
        }
      } else {
        guard let providerID = CloudProviderID(rawValue: active.route.providerID) else { throw CloudProviderError.invalidResponse }
        prepared = try CloudContext.prepare(ChatRequest(sessionID: selectedSessionID ?? UUID(), messages: [message], route: active.route))
        stream = cloudProviders.provider(for: providerID).textStream(ChatRequest(
          sessionID: selectedSessionID ?? UUID(), messages: prepared.messages, route: active.route))
      }
      contextualQuery = try ScreenSearchContext.query(from:
        await ScreenSearchContext.collect(stream, maximumBytes: 1_024))
      try Task.checkCancellation()
      guard activeRequest?.id == requestID else { throw CancellationError() }
      state = .searching
      receiveActivity(.phase(.searching), requestID: requestID)
    }
    if LocationIntent.needsLocation(locationPrompt ?? query), let locationProvider {
      let location = try await locationProvider.currentLocation()
      try Task.checkCancellation()
      guard activeRequest?.id == requestID else { throw CancellationError() }
      requestLocationContext = location.searchContext
      contextualQuery += "\n" + location.searchContext
    }
    let results = try await webSearch.search(contextualQuery, maximumTokens: maximumTokens) { [weak self] event in
      // Retrieval candidates are not citation sources until context fitting selects them.
      if case .sourcesDiscovered = event {
        await self?.receiveActivity(.phase(.readingSources), requestID: requestID)
      }
    }
    try Task.checkCancellation()
    receiveActivity(.phase(.readingSources), requestID: requestID)
    return results
  }

  private func receiveActivity(_ event: AssistantActivityEvent, requestID: UUID) {
    guard activeRequest?.id == requestID, var updated = activity else { return }
    updated.apply(event)
    guard updated != activity else { return }
    activity = updated
    guard activeRequest?.id == requestID, let messageID = activityMessageID,
          let sessionIndex = sessions.firstIndex(where: { $0.messages.contains(where: { $0.id == messageID }) }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
    sessions[sessionIndex].messages[messageIndex].activity = updated
  }

  private func locationGrounded(_ messages: [ChatMessage]) -> [ChatMessage] {
    guard let context = requestLocationContext, !messages.isEmpty else { return messages }
    var result = messages
    result[result.count - 1].content += "\n\n" + context + "\nUse this area for this question only; mention the area in your answer."
    return result
  }

  private func beginGeneration(route: Route, modelDisplayName: String) -> ActiveRequest {
    requestLocationContext = nil
    let request = ActiveRequest(id: UUID(), route: route, modelDisplayName: modelDisplayName)
    pendingUserMessage = nil
    hasReceivedResponse = false
    activeRequest = request
    selectionEditRequest = attachedContexts.first(where: { $0.kind == .selectedText }).map {
      (request.id, $0.id, selectionEditingSettings.automaticallyReplace)
    }
    activityMessageID = nil
    activity = AssistantActivity(id: request.id)
    return request
  }

  func selectionDisplayMessage(_ message: ChatMessage) -> ChatMessage {
    guard isTemporaryChat, message.role == .assistant, !attachedContexts.isEmpty || selectionRevisions[message.id] != nil else { return message }
    var copy = message
    copy.content = SelectionRevisionResponse.visibleText(message.content, streaming: activeRequest != nil)
    return copy
  }

  func updateSelectionRevision(messageID: UUID, text: String) {
    guard selectionRevisions[messageID]?.status == .ready || selectionRevisions[messageID]?.status == .failed else { return }
    selectionRevisions[messageID]?.text = text
  }

  func applySelectionRevision(messageID: UUID) async {
    guard !Task.isCancelled, activeRequest == nil, !isApplyingSelection, let revision = selectionRevisions[messageID],
          revision.status == .ready || revision.status == .failed,
          attachedContexts.contains(where: { $0.id == revision.contextID }), !revision.text.isEmpty else { return }
    if revision.automatic && !selectionEditingSettings.automaticallyReplace { return }
    isApplyingSelection = true
    selectionRevisions[messageID]?.status = .applying
    defer { isApplyingSelection = false }
    let sent = await replaceSelection(revision.text, revision.contextID)
    guard selectionRevisions[messageID]?.contextID == revision.contextID else { return }
    selectionRevisions[messageID]?.status = sent ? .sent : .failed
    if !sent && revision.automatic { contextNotice = "Automatic replacement was not sent. Select the source text again and retry." }
  }

  private func recoverSelectionResponse(active: ActiveRequest) async throws -> SelectionRevisionResponse.Recovery? {
    // One bounded model recovery, using the same provider and context. Never retry a paste.
    var instruction = contextualMessage(SelectionRevisionResponse.recoveryInstructions, editing: false)
    if let draft = instruction.selectionDraft {
      instruction.contexts?.append(ConversationContext(kind: .file, sourceName: "Latest proposed revision", text: draft))
    }
    let history = requestMessages + [instruction]
    let stream: AsyncThrowingStream<String, Error>
    if active.route.mode == .local {
      guard let model = await engine.installedModel(), model.id == active.route.modelID else {
        throw LocalInferenceError.noModelInstalled
      }
      if model.supportsVision {
        let prepared = try await visionEngine.prepare(messages: history, image: nil, model: model)
        stream = visionEngine.stream(messages: prepared.messages, image: nil, model: model, temperature: 0)
      } else {
        let prepared = try await engine.prepare(LocalModelRequest(messages: history))
        stream = engine.stream(LocalModelRequest(messages: prepared.messages, temperature: 0))
      }
    } else {
      guard let providerID = CloudProviderID(rawValue: active.route.providerID) else { throw CloudProviderError.invalidResponse }
      let prepared = try CloudContext.prepare(ChatRequest(sessionID: selectedSessionID ?? UUID(), messages: history, route: active.route))
      stream = cloudProviders.provider(for: providerID).textStream(ChatRequest(
        sessionID: selectedSessionID ?? UUID(), messages: prepared.messages, route: active.route))
    }
    return SelectionRevisionResponse.recover(try await ScreenSearchContext.collect(stream, maximumBytes: 300_000))
  }

  private func finishGeneration(id: UUID, error: Error? = nil) async {
    if error == nil, !Task.isCancelled, let active = activeRequest, active.id == id,
       let editing = selectionEditRequest, editing.id == id,
       attachedContexts.contains(where: { $0.id == editing.contextID }),
       let message = messages.last, message.role == .assistant, !message.content.isEmpty,
       !message.content.contains(SelectionRevisionResponse.opening) {
      do {
        let recovery = try await recoverSelectionResponse(active: active)
        try Task.checkCancellation()
        guard activeRequest?.id == id else { return }
        if selectionEditRequest?.id == id, attachedContexts.contains(where: { $0.id == editing.contextID }) {
          switch recovery {
          case .revision(let response):
            if let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
               let index = sessions[sessionIndex].messages.firstIndex(where: { $0.id == message.id }) {
              sessions[sessionIndex].messages[index].content = response.formatted
            }
          case .answer: break
          case nil: contextNotice = "The model could not prepare a revised-text card. Ask it to try again."
          }
        }
      } catch {
        if !Task.isCancelled, activeRequest?.id == id, selectionEditRequest?.id == id {
          contextNotice = "The revised-text card could not be prepared. Please try again."
        }
      }
    }
    guard activeRequest?.id == id else { return }
    if error == nil, !Task.isCancelled, let editing = selectionEditRequest, editing.id == id,
       attachedContexts.contains(where: { $0.id == editing.contextID }), let message = messages.last, message.role == .assistant {
      if let response = SelectionRevisionResponse.parse(message.content) {
        let automatic = editing.automatic && selectionEditingSettings.automaticallyReplace
        selectionRevisions[message.id] = SelectionRevision(id: message.id, contextID: editing.contextID,
          text: response.text, automatic: automatic)
        if automatic {
          replacementTask = Task { [weak self] in await self?.applySelectionRevision(messageID: message.id) }
        }
      } else if message.content.contains(SelectionRevisionResponse.opening) {
        contextNotice = "The model did not return a complete revision. Ask it to try again."
      }
    }
    selectionEditRequest = nil
    receiveActivity(.phase(error == nil ? .completed : .failed), requestID: id)
    activeRequest = nil
    activity = nil
    activityMessageID = nil
    pendingUserMessage = nil
    generationTask = nil
    state = error.map { .failed($0.localizedDescription) } ?? .idle
  }
}
