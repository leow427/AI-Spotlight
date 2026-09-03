import Combine
import Foundation

struct LocalChatMessage: Identifiable, Equatable {
  enum Role: Equatable {
    case user
    case assistant
  }

  let id: UUID
  let role: Role
  var content: String

  init(id: UUID = UUID(), role: Role, content: String) {
    self.id = id
    self.role = role
    self.content = content
  }
}

@MainActor
final class LocalChatViewModel: ObservableObject {
  enum State: Equatable {
    case idle
    case installing
    case preparing
    case streaming
    case failed(String)
  }

  typealias Sleep = @Sendable (Duration) async throws -> Void

  @Published private(set) var messages: [LocalChatMessage] = []
  @Published private(set) var installedModel: LocalModel?
  @Published private(set) var state: State = .idle

  private let engine: any LocalModelEngine
  private let idleUnloadDelay: Duration
  private let sleep: Sleep
  private var generationTask: Task<Void, Never>?
  private var installationTask: Task<Void, Never>?
  private var idleUnloadTask: Task<Void, Never>?

  var isBusy: Bool {
    switch state {
    case .installing, .preparing, .streaming:
      true
    case .idle, .failed:
      false
    }
  }

  init(
    engine: any LocalModelEngine,
    idleUnloadDelay: Duration = .seconds(300),
    sleep: @escaping Sleep = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.engine = engine
    self.idleUnloadDelay = idleUnloadDelay
    self.sleep = sleep
  }

  func refreshInstalledModel() async {
    installedModel = await engine.installedModel()
  }

  func installModel(from sourceURL: URL) {
    stopStreaming()
    installationTask?.cancel()
    idleUnloadTask?.cancel()
    state = .installing
    let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    let modelName = sourceURL.deletingPathExtension().lastPathComponent
    let model = LocalModel(
      id: modelName.lowercased(),
      displayName: modelName,
      fileURL: sourceURL
    )

    installationTask = Task { [weak self, engine] in
      defer {
        if didAccessSecurityScope {
          sourceURL.stopAccessingSecurityScopedResource()
        }
      }
      do {
        try await engine.install(model)
        guard !Task.isCancelled else { return }
        let installedModel = await engine.installedModel()
        guard let self else { return }
        self.installedModel = installedModel
        self.state = .idle
        self.installationTask = nil
      } catch is CancellationError {
        guard let self else { return }
        self.state = .idle
        self.installationTask = nil
      } catch {
        guard let self else { return }
        self.state = .failed(error.localizedDescription)
        self.installationTask = nil
      }
    }
  }

  func submit(_ prompt: String) {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty, !isBusy else { return }

    idleUnloadTask?.cancel()
    let responseID = UUID()
    messages.append(LocalChatMessage(role: .user, content: trimmedPrompt))
    messages.append(LocalChatMessage(id: responseID, role: .assistant, content: ""))
    state = .preparing

    generationTask = Task { [weak self, engine] in
      do {
        let stream = engine.stream(LocalModelRequest(prompt: trimmedPrompt))
        for try await fragment in stream {
          try Task.checkCancellation()
          guard let self else { return }
          self.state = .streaming
          self.append(fragment, to: responseID)
        }
        guard !Task.isCancelled, let self else { return }
        self.state = .idle
        self.generationTask = nil
      } catch is CancellationError {
        guard let self else { return }
        self.state = .idle
        self.generationTask = nil
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
    if isBusy {
      state = .idle
    }
  }

  func newChat() {
    stopStreaming()
    messages.removeAll()
    if case .failed = state {
      state = .idle
    }
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

  private func append(_ fragment: String, to messageID: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
    messages[index].content.append(fragment)
  }
}
