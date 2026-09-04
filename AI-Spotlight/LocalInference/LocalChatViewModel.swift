import Combine
import Foundation

@MainActor
final class LocalChatViewModel: ObservableObject {
  static let shared = LocalChatViewModel(engine: LlamaCPPModelEngine(), modelAdvisor: .shared)

  enum State: Equatable {
    case idle
    case installing
    case benchmarking
    case downloading(ModelDownloadProgress)
    case preparing
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
  @Published private(set) var activeRequest: ActiveRequest?
  @Published private(set) var autoRouteDecision: AutoRouter.Decision?
  @Published private(set) var state: State = .idle
  @Published private(set) var benchmarkNotice: String?
  private let modelAdvisor: LocalModelAdvisor?

  var messages: [ChatMessage] { selectedSession?.messages ?? [] }

  var selectedSession: ChatSession? {
    guard let selectedSessionID else { return nil }
    return sessions.first(where: { $0.id == selectedSessionID })
  }

  var isBusy: Bool {
    // A persistence error must not make a live request accept another submission.
    if activeRequest != nil || generationTask != nil || installationTask != nil { return true }
    switch state {
    case .installing, .downloading, .benchmarking, .preparing, .searching, .streaming: return true
    case .idle, .failed: return false
    }
  }

  private let engine: any LocalModelEngine
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
    modelAdvisor: LocalModelAdvisor? = nil,
    cloudProviders: CloudProviderRegistry = .live,
    webSearch: any WebSearchProvider = BraveSearchClient(),
    sessionStore: ChatSessionStore = ChatSessionStore(),
    idleUnloadDelay: Duration = .seconds(300),
    sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
  ) {
    self.engine = engine
    self.modelAdvisor = modelAdvisor
    self.webSearch = webSearch
    self.cloudProviders = cloudProviders
    self.sessionStore = sessionStore
    self.idleUnloadDelay = idleUnloadDelay
    self.sleep = sleep
    sessions = sessionStore.load()
    selectedSessionID = sessions.first?.id
  }

  func refreshInstalledModel() async {
    installedModel = await engine.installedModel()
    installedModels = await engine.installedModels()
  }

  func installModel(from sourceURL: URL) {
    guard !isBusy else { return }
    stopStreaming()
    installationTask?.cancel()
    idleUnloadTask?.cancel()
    state = .installing
    let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    let modelName = sourceURL.deletingPathExtension().lastPathComponent
    let model = LocalModel(id: modelName.lowercased(), displayName: modelName, fileURL: sourceURL)

    installationTask = Task { [weak self, engine] in
      defer {
        if didAccessSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
      }
      do {
        try await engine.install(model)
        guard let self else { return }
        await self.refreshInstalledModel()
        try Task.checkCancellation()
        await self.benchmarkInstalledModel(prediction: nil)
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
    state = .downloading(ModelDownloadProgress(receivedByteCount: 0, expectedByteCount: descriptor.expectedByteCount))
    installationTask = Task { [weak self, engine] in
      do {
        let prediction = try await self?.modelAdvisor?.confirmDownload(descriptor, installedModels: self?.installedModels ?? [])
        try Task.checkCancellation()
        _ = try await engine.download(descriptor) { [weak self] progress in
          await self?.updateDownloadProgress(progress)
        }
        guard let self else { return }
        await self.refreshInstalledModel()
        try Task.checkCancellation()
        await self.benchmarkInstalledModel(prediction: prediction)
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
    guard !isBusy, installedModel != nil else { return }
    idleUnloadTask?.cancel()
    state = .benchmarking
    installationTask = Task { [weak self] in
      guard let self else { return }
      await modelAdvisor?.detectHardware()
      let prediction = modelAdvisor?.recommendations(installedModels: installedModels)
        .assessments.first { $0.id == installedModel?.id }
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
      if let metrics = try await engine.benchmark() {
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
        try await engine.selectModel(id: id)
        guard let self else { return }
        await self.refreshInstalledModel()
        self.state = .idle
      } catch {
        self?.state = .failed(error.localizedDescription)
      }
    }
  }

  func submit(_ prompt: String, searchEnabled: Bool = false, onAccepted: @escaping @MainActor () -> Void = {}) {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty, !isBusy else { return }
    idleUnloadTask?.cancel()
    let responseID = UUID()
    let userMessage = ChatMessage(role: .user, content: trimmedPrompt)
    let request = LocalModelRequest(messages: messages + [userMessage])
    let active = beginGeneration(
      route: Route(mode: .local, providerID: "local", modelID: installedModel?.id ?? "", usesNetwork: searchEnabled),
      modelDisplayName: installedModel?.displayName ?? "Local model"
    )
    contextNotice = nil
    state = .preparing

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
          let results = try await owner.webSearch.search(trimmedPrompt, maximumTokens: 1_024)
          try Task.checkCancellation()
          guard owner.activeRequest?.id == active.id else { return }
          owner.state = .preparing
          let grounded = try await WebSearchContext.prepare(messages: request.messages, results: results) {
            try await engine.prepare(LocalModelRequest(messages: $0))
          }
          prepared = grounded.prepared
          sources = grounded.sources
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
        for try await fragment in engine.stream(boundedRequest) {
          try Task.checkCancellation()
          guard let self, self.activeRequest?.id == active.id else { return }
          self.state = .streaming
          self.append(fragment, to: responseID, in: sessionID)
        }
        try Task.checkCancellation()
        self?.finishGeneration(id: active.id)
      } catch is CancellationError {
        self?.finishGeneration(id: active.id)
      } catch {
        self?.finishGeneration(id: active.id, error: error)
      }
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
    guard !trimmedPrompt.isEmpty, !trimmedModelID.isEmpty, !isBusy else { return }
    idleUnloadTask?.cancel()
    let route = Route(
      mode: .cloud,
      providerID: providerID.rawValue,
      modelID: trimmedModelID,
      usesNetwork: true
    )
    let userMessage = ChatMessage(role: .user, content: trimmedPrompt)
    let prepared: PreparedConversation
    contextNotice = nil
    do {
      prepared = try CloudContext.prepare(ChatRequest(
        sessionID: selectedSessionID ?? UUID(), messages: messages + [userMessage], route: route
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
        for try await event in provider.stream(request) {
          try Task.checkCancellation()
          guard let self, self.activeRequest?.id == active.id else { return }
          switch event {
          case .token(let fragment):
            self.state = .streaming
            self.append(fragment, to: responseID, in: sessionID)
          case .completed:
            break
          }
        }
        try Task.checkCancellation()
        self?.finishGeneration(id: active.id)
      } catch is CancellationError {
        self?.finishGeneration(id: active.id)
      } catch {
        self?.finishGeneration(id: active.id, error: error)
      }
    }
    // Install the handle before calling out: acceptance may synchronously Stop or start a new chat.
    onAccepted()
  }

  private func submitCloudWithSearch(
    _ userMessage: ChatMessage, route: Route, onAccepted: @escaping @MainActor () -> Void
  ) {
    let history = messages + [userMessage]
    let active = beginGeneration(route: route, modelDisplayName: route.modelID)
    state = .searching
    generationTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        guard let owner = self, owner.activeRequest?.id == active.id else { return }
        let results = try await owner.webSearch.search(userMessage.content, maximumTokens: 4_096)
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        let grounded = try await WebSearchContext.prepare(messages: history, results: results) {
          try CloudContext.prepare(ChatRequest(sessionID: UUID(), messages: $0, route: route))
        }
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id,
              let providerID = CloudProviderID(rawValue: route.providerID) else { return }
        let sessionID = owner.ensureSelectedSession()
        let responseID = UUID()
        owner.contextNotice = grounded.prepared.notice
        owner.state = .preparing
        owner.append(userMessage, to: sessionID)
        owner.append(ChatMessage(id: responseID, role: .assistant, content: "", searchSources: grounded.sources), to: sessionID)
        onAccepted()
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        let request = ChatRequest(sessionID: sessionID, messages: grounded.prepared.messages, route: route)
        let provider = owner.cloudProviders.provider(for: providerID)
        for try await event in provider.stream(request) {
          try Task.checkCancellation()
          guard owner.activeRequest?.id == active.id else { return }
          if case .token(let fragment) = event {
            owner.state = .streaming
            owner.append(fragment, to: responseID, in: sessionID)
          }
        }
        try Task.checkCancellation()
        owner.finishGeneration(id: active.id)
      } catch is CancellationError {
        self?.finishGeneration(id: active.id)
      } catch {
        self?.finishGeneration(id: active.id, error: error)
      }
    }
  }

  func submitAuto(
    _ prompt: String,
    cloud: AutoRouter.CloudConfiguration?,
    searchEnabled: Bool = false,
    onAccepted: @escaping @MainActor () -> Void = {}
  ) {
    guard !isBusy, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    state = .idle
    contextNotice = nil
    let decision = (searchEnabled || AutoRouter.shouldRun(for: .auto, cloud: cloud))
      ? AutoRouter.decide(AutoRouter.Request(
        selectedMode: .auto, webSearchEnabled: searchEnabled, prompt: prompt, contextMessages: messages,
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
    // Revoke ownership before cancellation can release any queued events or cleanup.
    activeRequest = nil
    generationTask = nil
    state = .idle
    task.cancel()
    return task
  }

  func newChat() {
    stopStreaming()
    contextNotice = nil
    autoRouteDecision = nil
    let session = ChatSession()
    sessions.append(session)
    selectedSessionID = session.id
    sortAndPersistSessions()
    if case .failed = state { state = .idle }
  }

  func selectSession(id: UUID) {
    guard sessions.contains(where: { $0.id == id }), !isBusy else { return }
    selectedSessionID = id
    contextNotice = nil
  }

  func cycleRecentChat() {
    guard !isBusy, !sessions.isEmpty else { return }
    contextNotice = nil
    let selectedIndex = selectedSessionID.flatMap { id in sessions.firstIndex(where: { $0.id == id }) }
    selectedSessionID = sessions[selectedIndex.map { ($0 + 1) % sessions.count } ?? 0].id
  }

  func applicationBecameActive() {
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
  }

  func applicationBecameInactive() {
    idleUnloadTask?.cancel()
    idleUnloadTask = Task { [engine, idleUnloadDelay, sleep] in
      do {
        try await sleep(idleUnloadDelay)
        try Task.checkCancellation()
        await engine.unload()
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
    sessions[index].append(message)
    sortAndPersistSessions()
  }

  private func append(_ fragment: String, to messageID: UUID, in sessionID: UUID) {
    guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
    sessions[sessionIndex].messages[messageIndex].content.append(fragment)
    sessions[sessionIndex].lastActivityAt = .now
    sortAndPersistSessions()
  }

  private func sortAndPersistSessions() {
    sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
    if sessions.count > ChatSessionStore.maximumRetainedSessions {
      sessions.removeLast(sessions.count - ChatSessionStore.maximumRetainedSessions)
    }
    persistSessions()
  }

  private func persistSessions() {
    do { try sessionStore.save(sessions) }
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
    state = .failed(error.localizedDescription)
    installationTask = nil
  }

  private func beginGeneration(route: Route, modelDisplayName: String) -> ActiveRequest {
    let request = ActiveRequest(id: UUID(), route: route, modelDisplayName: modelDisplayName)
    activeRequest = request
    return request
  }

  private func finishGeneration(id: UUID, error: Error? = nil) {
    guard activeRequest?.id == id else { return }
    activeRequest = nil
    generationTask = nil
    state = error.map { .failed($0.localizedDescription) } ?? .idle
  }
}
