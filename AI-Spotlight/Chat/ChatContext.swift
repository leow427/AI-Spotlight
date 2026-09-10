import Foundation

struct ContextBudget: Equatable, Sendable {
  let contextWindow: Int
  let outputTokens: Int
  let overheadTokens: Int
  var inputLimit: Int = .max

  var availableInputTokens: Int {
    max(0, min(inputLimit, contextWindow - outputTokens - overheadTokens))
  }
}

/// Shared by request preparation, Auto, and model-selection metadata. Limits for
/// unverified IDs are application policy, not claims about provider capabilities.
enum ModelContextPolicy {
  static let localContextWindow = 4_096
  static let localOutputTokens = 512

  static func cloud(provider: CloudProviderID, modelID: String) -> ContextBudget {
    let metadata = CloudModelCapabilities.metadata(provider: provider, modelID: modelID)
    if provider == .chatGPT {
      return ContextBudget(
        contextWindow: metadata?.contextWindow ?? 32_768,
        outputTokens: metadata?.maximumOutputTokens ?? 16_384,
        overheadTokens: 8_192,
        inputLimit: 32_768
      )
    }
    return ContextBudget(
      contextWindow: metadata?.contextWindow ?? 8_192,
      outputTokens: min(4_096, metadata?.maximumOutputTokens ?? 4_096),
      overheadTokens: 512,
      inputLimit: 32_768
    )
  }
}

extension CloudModel {
  var contextBudget: ContextBudget {
    ModelContextPolicy.cloud(provider: provider, modelID: id)
  }
}

enum ChatContextError: LocalizedError, Equatable {
  case missingCurrentPrompt
  case oversizedPrompt(inputLimit: Int)
  case invalidText

  var errorDescription: String? {
    switch self {
    case .missingCurrentPrompt:
      "Enter a message before sending."
    case .oversizedPrompt(let inputLimit):
      "This message and its attached context exceed the selected model's input budget (\(inputLimit) tokens after reserving reply space). Shorten it or choose a model with a larger context. Your draft has been kept."
    case .invalidText:
      "This message contains a null character that the local model cannot read. Remove it and try again. Your draft has been kept."
    }
  }
}

struct PreparedConversation: Equatable, Sendable {
  let messages: [ChatMessage]
  let inputTokenCount: Int
  let omittedMessageCount: Int
  let budget: ContextBudget

  var notice: String? {
    guard omittedMessageCount > 0 else { return nil }
    return "\(omittedMessageCount) earlier messages were omitted from this request to fit the model's context or keep complete turns. Saved chat history is unchanged."
  }
}

enum ChatContextPreparer {
  /// Uses the same complete-turn selection policy with an asynchronous runtime tokenizer.
  static func prepareAsync(
    _ messages: [ChatMessage], budget: ContextBudget,
    countTokens: ([ChatMessage]) async throws -> Int
  ) async throws -> PreparedConversation {
    let canonical = try prepare(messages, budget: budget, countTokens: { _ in 0 }).messages
    var retained = [canonical[canonical.count - 1]]
    try Task.checkCancellation()
    var count = try await countTokens(retained)
    guard count >= 0, count <= budget.availableInputTokens else {
      throw ChatContextError.oversizedPrompt(inputLimit: budget.availableInputTokens)
    }
    for start in stride(from: canonical.count - 3, through: 0, by: -2) {
      try Task.checkCancellation()
      let candidate = Array(canonical[start...])
      let candidateCount = try await countTokens(candidate)
      guard candidateCount >= 0, candidateCount <= budget.availableInputTokens else { break }
      retained = candidate
      count = candidateCount
    }
    try Task.checkCancellation()
    return PreparedConversation(messages: retained, inputTokenCount: count,
      omittedMessageCount: messages.count - retained.count, budget: budget)
  }

  /// A request is a suffix of complete user/assistant turns plus the current user
  /// message. Empty placeholders and unanswered/otherwise orphaned turns stay on
  /// disk, but cannot become misleading context for a later question.
  static func prepare(
    _ messages: [ChatMessage],
    budget: ContextBudget,
    countTokens: ([ChatMessage]) throws -> Int
  ) throws -> PreparedConversation {
    let messages = messages.map(ConversationContextPrompt.expand)
    guard var current = messages.last, current.role == .user,
          !current.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ChatContextError.missingCurrentPrompt
    }
    if current.extendedThinking == true, !current.content.hasPrefix(ThinkCommand.guidance) {
      current.content = ThinkCommand.guidance + "\n\n" + current.content
    }
    var retained = [current]
    var tokenCount = try countTokens(retained)
    guard budget.outputTokens > 0, tokenCount <= budget.availableInputTokens else {
      throw ChatContextError.oversizedPrompt(inputLimit: budget.availableInputTokens)
    }

    var turns: [[ChatMessage]] = []
    var index = 0
    while index + 1 < messages.count - 1 {
      let user = messages[index]
      let assistant = messages[index + 1]
      if user.role == .user, assistant.role == .assistant,
         !user.content.isEmpty, !assistant.content.isEmpty {
        turns.append([user, assistant])
        index += 2
      } else {
        index += 1
      }
    }
    for turn in turns.reversed() {
      let candidate = turn + retained
      let candidateCount = try countTokens(candidate)
      guard candidateCount <= budget.availableInputTokens else { break }
      retained = candidate
      tokenCount = candidateCount
    }
    return PreparedConversation(
      messages: retained,
      inputTokenCount: tokenCount,
      omittedMessageCount: messages.count - retained.count,
      budget: budget
    )
  }
}

enum CloudContext {
  private struct Message: Encodable {
    let role: String
    let content: String
  }

  static func encodedMessages(_ messages: [ChatMessage]) throws -> Data {
    try JSONEncoder().encode(messages.map { Message(role: $0.role.rawValue, content: $0.content) })
  }

  static func codexPrompt(_ messages: [ChatMessage]) throws -> String {
    if messages.count == 1 { return messages[0].content }
    return "Continue this conversation:\n" + String(decoding: try encodedMessages(messages), as: UTF8.self)
  }

  /// One UTF-8 byte per token deliberately overestimates text tokenization,
  /// including JSON escaping/role wrappers. Hidden protocol text has its own reserve.
  static func inputTokenCount(_ messages: [ChatMessage], provider: CloudProviderID) throws -> Int {
    if provider == .chatGPT { return try codexPrompt(messages).utf8.count }
    return try encodedMessages(messages).count
  }

  static func prepare(_ request: ChatRequest) throws -> PreparedConversation {
    try ScreenRequestGuard.validateCloud(request)
    guard let provider = CloudProviderID(rawValue: request.route.providerID) else {
      throw CloudProviderError.invalidResponse
    }
    if CloudModelCapabilities.compatibility(provider: provider, modelID: request.route.modelID) == .unsupported {
      throw CloudProviderError.unsupportedModel(provider, modelID: request.route.modelID)
    }
    return try ChatContextPreparer.prepare(
      request.messages,
      budget: ModelContextPolicy.cloud(provider: provider, modelID: request.route.modelID),
      countTokens: { try inputTokenCount($0, provider: provider) + (request.image == nil ? 0 : 4096) }
    )
  }
}

/// Shared response style guidance, independent of provider and persisted history.
enum ChatResponseStyle {
  static let instructions = """
    Be quick and helpful. Lead with the answer or requested edit. For everyday questions, aim for one short paragraph or 3–5 brief bullets, usually under 150 words. Include the details needed to act, but skip preambles, repeated conclusions, unsolicited follow-up offers, and unnecessary headings. For edits, return the revised text with only essential explanation. Expand when the user asks for depth or when accuracy, safety, or a complete deliverable requires it; never omit essential steps or truncate code to meet a length target.
    For nearby or local-weather questions, use a place named by the user or approximate location supplied for this request. If neither is available, ask for a city or area; never guess the user's location or invent current weather or opening hours.
    Use clean standard Markdown for responses: headings, lists, emphasis, code, links, blockquotes, and tables when useful. Do not put backslashes before Markdown formatting characters. Preserve literal backslashes in paths and code; put code and paths in code spans or fenced code blocks.
    """
}
