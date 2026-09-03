import Combine
import Foundation

@MainActor
final class LocalChatViewModel: ObservableObject {
  enum State: Equatable {
    case idle
    case installing
    case downloading(ModelDownloadProgress)
    case preparing
    case streaming
    case failed(String)
  }

  typealias Sleep = @Sendable (Duration) async throws -> Void

  @Published private(set) var sessions: [ChatSession]
  @Published private(set) var selectedSessionID: UUID?
  @Published private(set) var installedModel: LocalModel?
  @Published private(set) var installedModels: [LocalModel] = []
  @Published private(set) var state: State = .idle

  var messages: [ChatMessage] { selectedSession?.messages ?? [] }

  var selectedSession: ChatSession? {
    guard let selectedSessionID else { return nil }
    return sessions.first(where: { $0.id == selectedSessionID })
  }

  var isBusy: Bool {
    switch state {
    case .installing, .downloading, .preparing, .streaming: true
    case .idle, .failed: false
    }
  }

  private let engine: any LocalModelEngine
  private let sessionStore: ChatSessionStore
  private let idleUnloadDelay: Duration
  private let sleep: Sleep
  private var generationTask: Task<Void, Never>?
  private var installationTask: Task<Void, Never>?
  private var idleUnloadTask: Task<Void, Never>?

  init(
    engine: any LocalModelEngine,
    sessionStore: ChatSessionStore = ChatSessionStore(),
    idleUnloadDelay: Duration = .seconds(300),
    sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
  ) {
    self.engine = engine
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
        guard !Task.isCancelled, let self else { return }
        await self.refreshInstalledModel()
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
    stopStreaming()
    installationTask?.cancel()
    idleUnloadTask?.cancel()
    state = .downloading(ModelDownloadProgress(receivedByteCount: 0, expectedByteCount: descriptor.expectedByteCount))
    installationTask = Task { [weak self, engine] in
      do {
        _ = try await engine.download(descriptor) { [weak self] progress in
          await self?.updateDownloadProgress(progress)
        }
        guard !Task.isCancelled, let self else { return }
        await self.refreshInstalledModel()
        self.state = .idle
        self.installationTask = nil
      } catch is CancellationError {
        self?.finishInstallation()
      } catch {
        self?.failInstallation(error)
      }
    }
  }

  func selectModel(id: String) {
    guard !isBusy else { return }
    Task { [weak self, engine] in
      do {
        try await engine.selectModel(id: id)
        guard let self else { return }
        await self.refreshInstalledModel()
      } catch {
        self?.state = .failed(error.localizedDescription)
      }
    }
  }

  func submit(_ prompt: String) {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty, !isBusy else { return }
    idleUnloadTask?.cancel()
    let responseID = UUID()
    let sessionID = ensureSelectedSession()
    append(ChatMessage(role: .user, content: trimmedPrompt), to: sessionID)
    append(ChatMessage(id: responseID, role: .assistant, content: ""), to: sessionID)
    state = .preparing

    generationTask = Task { [weak self, engine] in
      do {
        for try await fragment in engine.stream(LocalModelRequest(prompt: trimmedPrompt)) {
          try Task.checkCancellation()
          guard let self else { return }
          self.state = .streaming
          self.append(fragment, to: responseID, in: sessionID)
        }
        guard !Task.isCancelled, let self else { return }
        self.state = .idle
        self.generationTask = nil
      } catch is CancellationError {
        self?.finishGeneration()
      } catch {
        guard let self else { return }
        self.state = .failed(error.localizedDescription)
        self.generationTask = nil
      }
    }
  }

  func stopStreaming() {
    guard state == .preparing || state == .streaming else { return }
    generationTask?.cancel()
    generationTask = nil
    state = .idle
  }

  func newChat() {
    stopStreaming()
    let session = ChatSession()
    sessions.append(session)
    selectedSessionID = session.id
    sortAndPersistSessions()
    if case .failed = state { state = .idle }
  }

  func selectSession(id: UUID) {
    guard sessions.contains(where: { $0.id == id }), !isBusy else { return }
    selectedSessionID = id
  }

  func cycleRecentChat() {
    guard !isBusy, !sessions.isEmpty else { return }
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

  private func finishGeneration() {
    state = .idle
    generationTask = nil
  }
}
