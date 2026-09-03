import Foundation

/// Selects the quickest route that can satisfy a request without asking another model.
struct AutoRouter: Sendable {
  enum Reason: Equatable, Sendable {
    case explicitMode
    case cloudUnavailable
    case noLocalModel
    case privateRequest
    case requiresWebSearch
    case exceedsLocalContext
    case requiresCoding
    case requiresAdvancedReasoning
    case localPreferred
  }

  enum Capability: Equatable, Sendable {
    case webSearch
    case coding
    case advancedReasoning
    case largerContext
  }

  enum Limitation: Equatable, Sendable {
    case noLocalModel
    case privateRequestRequiresLocalModel
    case unavailableCapability(Capability)

    var message: String {
      switch self {
      case .noLocalModel:
        "Choose a local model or connect Cloud before using Auto."
      case .privateRequestRequiresLocalModel:
        "This request stays on-device. Choose a local model to continue."
      case .unavailableCapability(.webSearch):
        "This request needs a web-capable cloud model, which is not configured."
      case .unavailableCapability(.coding):
        "No available model is configured for this coding request."
      case .unavailableCapability(.advancedReasoning):
        "No available model is configured for this reasoning request."
      case .unavailableCapability(.largerContext):
        "This chat exceeds the available model context."
      }
    }
  }

  enum ReasoningLevel: Int, Comparable, Sendable {
    case basic
    case advanced

    static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  struct ModelCapabilities: Equatable, Sendable {
    let maximumContextTokens: Int
    let supportsCoding: Bool
    let supportsWebSearch: Bool
    let reasoningLevel: ReasoningLevel

    static let localDefault = Self(
      maximumContextTokens: 4_096,
      supportsCoding: false,
      supportsWebSearch: false,
      reasoningLevel: .basic
    )

    static let cloudDefault = Self(
      maximumContextTokens: 128_000,
      supportsCoding: true,
      supportsWebSearch: false,
      reasoningLevel: .advanced
    )
  }

  struct CloudConfiguration: Equatable, Sendable {
    let provider: CloudProviderID
    let modelID: String
    let modelDisplayName: String
    let capabilities: ModelCapabilities

    init(
      provider: CloudProviderID,
      modelID: String,
      modelDisplayName: String? = nil,
      capabilities: ModelCapabilities = .cloudDefault
    ) {
      self.provider = provider
      self.modelID = modelID
      self.modelDisplayName = modelDisplayName ?? modelID
      self.capabilities = capabilities
    }
  }

  struct Request: Equatable, Sendable {
    let selectedMode: ChatMode
    let prompt: String
    let contextMessages: [ChatMessage]
    let localModel: LocalModel?
    let localCapabilities: ModelCapabilities
    let cloud: CloudConfiguration?

    init(
      selectedMode: ChatMode,
      prompt: String,
      contextMessages: [ChatMessage],
      localModel: LocalModel?,
      localCapabilities: ModelCapabilities = .localDefault,
      cloud: CloudConfiguration?
    ) {
      self.selectedMode = selectedMode
      self.prompt = prompt
      self.contextMessages = contextMessages
      self.localModel = localModel
      self.localCapabilities = localCapabilities
      self.cloud = cloud
    }
  }

  struct Decision: Equatable, Sendable {
    let route: Route?
    let modelDisplayName: String?
    let reason: Reason
    let limitation: Limitation?
  }

  /// The app uses this gate so prompt classification is skipped when Auto cannot use Cloud.
  static func shouldRun(for mode: ChatMode, cloud: CloudConfiguration?) -> Bool {
    mode == .auto && cloud != nil
  }

  /// Returns the local-only result without examining prompt content.
  static func localFallback(localModel: LocalModel?) -> Decision {
    guard let localModel else {
      return Decision(
        route: nil,
        modelDisplayName: nil,
        reason: .cloudUnavailable,
        limitation: .noLocalModel
      )
    }
    return localDecision(for: localModel, reason: .cloudUnavailable)
  }

  static func decide(_ request: Request) -> Decision {
    switch request.selectedMode {
    case .local:
      guard let localModel = request.localModel else {
        return Decision(
          route: nil,
          modelDisplayName: nil,
          reason: .noLocalModel,
          limitation: .noLocalModel
        )
      }
      return localDecision(for: localModel, reason: .explicitMode)

    case .cloud:
      guard let cloud = request.cloud else {
        return Decision(
          route: nil,
          modelDisplayName: nil,
          reason: .cloudUnavailable,
          limitation: .unavailableCapability(.advancedReasoning)
        )
      }
      return cloudDecision(for: cloud, reason: .explicitMode)

    case .auto:
      guard let cloud = request.cloud else {
        return localFallback(localModel: request.localModel)
      }
      return automaticDecision(for: request, cloud: cloud)
    }
  }

  private static func automaticDecision(
    for request: Request,
    cloud: CloudConfiguration
  ) -> Decision {
    let prompt = request.prompt.lowercased()
    if explicitlyPrivate(prompt) {
      guard let localModel = request.localModel else {
        return Decision(
          route: nil,
          modelDisplayName: nil,
          reason: .privateRequest,
          limitation: .privateRequestRequiresLocalModel
        )
      }
      return localDecision(for: localModel, reason: .privateRequest)
    }

    if requiresWebSearch(prompt) {
      guard cloud.capabilities.supportsWebSearch else {
        return Decision(
          route: nil,
          modelDisplayName: nil,
          reason: .requiresWebSearch,
          limitation: .unavailableCapability(.webSearch)
        )
      }
      return cloudDecision(for: cloud, reason: .requiresWebSearch)
    }

    let contextTokenCount = estimatedTokens(
      for: request.prompt,
      contextMessages: request.contextMessages
    )
    if contextTokenCount > request.localCapabilities.maximumContextTokens {
      guard cloud.capabilities.maximumContextTokens >= contextTokenCount else {
        return Decision(
          route: nil,
          modelDisplayName: nil,
          reason: .exceedsLocalContext,
          limitation: .unavailableCapability(.largerContext)
        )
      }
      return cloudDecision(for: cloud, reason: .exceedsLocalContext)
    }

    if requiresCoding(prompt) {
      guard cloud.capabilities.supportsCoding else {
        if request.localCapabilities.supportsCoding, let localModel = request.localModel {
          return localDecision(for: localModel, reason: .localPreferred)
        }
        return Decision(
          route: nil,
          modelDisplayName: nil,
          reason: .requiresCoding,
          limitation: .unavailableCapability(.coding)
        )
      }
      return cloudDecision(for: cloud, reason: .requiresCoding)
    }

    if requiresAdvancedReasoning(prompt) {
      guard cloud.capabilities.reasoningLevel >= .advanced else {
        if request.localCapabilities.reasoningLevel >= .advanced,
           let localModel = request.localModel {
          return localDecision(for: localModel, reason: .localPreferred)
        }
        return Decision(
          route: nil,
          modelDisplayName: nil,
          reason: .requiresAdvancedReasoning,
          limitation: .unavailableCapability(.advancedReasoning)
        )
      }
      return cloudDecision(for: cloud, reason: .requiresAdvancedReasoning)
    }

    if let localModel = request.localModel {
      return localDecision(for: localModel, reason: .localPreferred)
    }
    return cloudDecision(for: cloud, reason: .noLocalModel)
  }

  private static func localDecision(for model: LocalModel, reason: Reason) -> Decision {
    Decision(
      route: Route(
        mode: .local,
        providerID: "local",
        modelID: model.id,
        usesNetwork: false
      ),
      modelDisplayName: model.displayName,
      reason: reason,
      limitation: nil
    )
  }

  private static func cloudDecision(for cloud: CloudConfiguration, reason: Reason) -> Decision {
    Decision(
      route: Route(
        mode: .cloud,
        providerID: cloud.provider.rawValue,
        modelID: cloud.modelID,
        usesNetwork: true
      ),
      modelDisplayName: cloud.modelDisplayName,
      reason: reason,
      limitation: nil
    )
  }

  private static func estimatedTokens(
    for prompt: String,
    contextMessages: [ChatMessage]
  ) -> Int {
    let characterCount = prompt.utf8.count
      + contextMessages.reduce(into: 0) { $0 += $1.content.utf8.count }
    // A conservative estimate keeps the router cheap and prevents local context overflows.
    return (characterCount + 3) / 4 + LocalModelRequest(prompt: "").maximumTokenCount
  }

  private static func explicitlyPrivate(_ prompt: String) -> Bool {
    containsAny(prompt, [
      "private information", "this is private", "keep this private",
      "do not send this", "don't send this", "do not share this",
      "don't share this", "confidential", "sensitive personal",
    ])
  }

  private static func requiresWebSearch(_ prompt: String) -> Bool {
    containsAny(prompt, [
      "search the web", "browse the web", "look this up", "look up the latest",
      "latest news", "current news", "current price", "today's price",
      "find online", "web search", "with citations",
    ])
  }

  private static func requiresCoding(_ prompt: String) -> Bool {
    containsAny(prompt, [
      "write code", "write a function", "implement ", "debug ", "stack trace",
      "swift", "python", "javascript", "typescript", "sql query", "regular expression",
    ])
  }

  private static func requiresAdvancedReasoning(_ prompt: String) -> Bool {
    containsAny(prompt, [
      "prove ", "derive ", "root cause analysis", "analyze the tradeoffs",
      "step-by-step reasoning", "optimization problem", "formalize ",
    ])
  }

  private static func containsAny(_ prompt: String, _ phrases: [String]) -> Bool {
    phrases.contains { prompt.contains($0) }
  }
}
