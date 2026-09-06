import Foundation

/// Selects the quickest route that can satisfy a request without asking another model.
struct AutoRouter: Sendable {
  enum Reason: Equatable, Sendable {
    case explicitMode
    case cloudUnavailable
    case noLocalModel
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
    case unavailableCapability(Capability)

    var message: String {
      switch self {
      case .noLocalModel:
        "Choose a local model or connect Cloud before using Auto."
      case .unavailableCapability(.webSearch):
        "Enable Web Search with the search icon or /search to look this up with Brave."
      case .unavailableCapability(.coding):
        "No available model is configured for this coding request."
      case .unavailableCapability(.advancedReasoning):
        "No available model is configured for this reasoning request."
      case .unavailableCapability(.largerContext):
        "This message exceeds the available model input budget. Shorten it or choose a model with a larger context. Your draft has been kept."
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
      maximumContextTokens: ModelContextPolicy.localContextWindow,
      supportsCoding: false,
      supportsWebSearch: false,
      reasoningLevel: .basic
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
      capabilities: ModelCapabilities? = nil
    ) {
      self.provider = provider
      self.modelID = modelID
      self.modelDisplayName = modelDisplayName ?? modelID
      self.capabilities = capabilities ?? ModelCapabilities(
        maximumContextTokens: ModelContextPolicy.cloud(provider: provider, modelID: modelID).contextWindow,
        supportsCoding: true, supportsWebSearch: false, reasoningLevel: .advanced
      )
    }
  }

  struct Request: Equatable, Sendable {
    let selectedMode: ChatMode
    let webSearchEnabled: Bool
    let prompt: String
    let contextMessages: [ChatMessage]
    let localModel: LocalModel?
    let localCapabilities: ModelCapabilities
    let additionalInputTokens: Int
    let cloud: CloudConfiguration?

    init(
      selectedMode: ChatMode,
      webSearchEnabled: Bool = false,
      prompt: String,
      contextMessages: [ChatMessage],
      localModel: LocalModel?,
      localCapabilities: ModelCapabilities? = nil,
      additionalInputTokens: Int = 0,
      cloud: CloudConfiguration?
    ) {
      self.selectedMode = selectedMode
      self.webSearchEnabled = webSearchEnabled
      self.prompt = prompt
      self.contextMessages = contextMessages
      self.localModel = localModel
      self.additionalInputTokens = max(0, min(additionalInputTokens, 1_000_000))
      self.localCapabilities = localCapabilities ?? ModelCapabilities(
        maximumContextTokens: localModel?.visionConfiguration?.contextWindow
          ?? localModel?.catalogDescriptor?.recommendedContextSize ?? ModelContextPolicy.localContextWindow,
        supportsCoding: localModel?.catalogDescriptor?.supportsVision == true,
        supportsWebSearch: false,
        reasoningLevel: localModel?.catalogDescriptor?.supportsVision == true ? .advanced : .basic)
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
    let decision = decideModel(request)
    guard request.webSearchEnabled, let route = decision.route else { return decision }
    return Decision(
      route: Route(mode: route.mode, providerID: route.providerID, modelID: route.modelID, usesNetwork: true),
      modelDisplayName: decision.modelDisplayName, reason: decision.reason, limitation: decision.limitation
    )
  }

  private static func decideModel(_ request: Request) -> Decision {
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

    if requiresWebSearch(prompt), !request.webSearchEnabled {
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

    let candidateMessages = request.contextMessages + [ChatMessage(role: .user, content: request.prompt)]
    let localBudget = ContextBudget(
      contextWindow: request.localCapabilities.maximumContextTokens,
      outputTokens: ModelContextPolicy.localOutputTokens, overheadTokens: 256
    )
    // This is a cheap conservative routing estimate. Local acceptance uses the
    // selected GGUF's real template/tokenizer and effective runtime context.
    let localInputCount = candidateMessages.reduce(request.additionalInputTokens) { $0 + $1.content.utf8.count + 32 }
    if localInputCount > localBudget.availableInputTokens {
      var cloudBudget = ModelContextPolicy.cloud(provider: cloud.provider, modelID: cloud.modelID)
      cloudBudget = ContextBudget(
        contextWindow: min(cloudBudget.contextWindow, cloud.capabilities.maximumContextTokens),
        outputTokens: cloudBudget.outputTokens, overheadTokens: cloudBudget.overheadTokens,
        inputLimit: cloudBudget.inputLimit
      )
      // A long saved transcript is trimmable; reject only when the latest prompt
      // cannot fit. Final preparation applies the same shared policy before send.
      let prepared = try? ChatContextPreparer.prepare(candidateMessages, budget: cloudBudget) {
        try CloudContext.inputTokenCount($0, provider: cloud.provider)
      }
      guard prepared != nil else {
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
    // Whole words avoid matches such as "design" in "designer". Splitting also
    // makes punctuation, repeated whitespace, and hyphen variants equivalent.
    let tokens = prompt.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let words = Set(tokens)
    let normalized = " " + tokens.joined(separator: " ") + " "

    // Strong reasoning requests should not depend on one exact stock phrase.
    if !words.isDisjoint(with: [
      "analyze", "analyse", "evaluate", "design", "solve", "calculate", "compute",
      "prove", "derive", "diagnose", "troubleshoot", "optimize", "optimise",
      "synthesize", "synthesise", "formalize", "formalise",
    ]) || containsAny(normalized, [
      " root cause ", " tradeoffs ", " trade offs ", " step by step reasoning ",
      " think deeply ", " optimization problem ", " optimisation problem ",
    ]) {
      return true
    }

    // Three points deliberately favor Cloud: two analytical actions, or one
    // action plus depth/constraints, outweigh the latency advantage of local.
    // Count distinct actions so repeating a word does not inflate complexity.
    let analyticalActions = words.intersection([
      "compare", "contrast", "assess", "justify", "recommend", "recommendation",
      "plan", "develop", "investigate", "choose", "infer",
    ])
    var score = min(analyticalActions.count, 2) * 2
    if !words.isDisjoint(with: ["explain", "explanation", "reason"]) {
      score += 1
    }
    if !words.isDisjoint(with: [
      "complex", "complicated", "advanced", "difficult", "rigorous", "thorough",
      "comprehensive", "detailed", "deep", "depth", "nuanced",
    ]) {
      score += 2
    }
    if !words.isDisjoint(with: [
      "probability", "proof", "hypothesis", "hypotheses", "causality",
      "counterfactual", "optimization", "optimisation",
    ]) {
      score += 2
    }
    if !words.isDisjoint(with: [
      "constraints", "dependencies", "assumptions", "risks", "alternatives",
      "criteria", "uncertainty", "limitations",
    ]) {
      score += 1
    }
    // Longer instructions strengthen other evidence, but length alone never
    // qualifies: a long passage to summarize can still use local context.
    if tokens.count >= 100 { score += 1 }
    if tokens.count >= 200 { score += 1 }
    return score >= 3
  }

  private static func containsAny(_ prompt: String, _ phrases: [String]) -> Bool {
    phrases.contains { prompt.contains($0) }
  }
}
