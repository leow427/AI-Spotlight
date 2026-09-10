import Foundation

enum CloudModelCompatibility: Equatable, Sendable {
  case unselected
  case compatible
  case unsupported
  case unverified

  var allowsSending: Bool {
    self == .compatible || self == .unverified
  }

  var message: String {
    switch self {
    case .unselected:
      "Choose a compatible model or enter a model ID."
    case .compatible:
      "Compatible with text chat. Account access and billing are checked when you send."
    case .unsupported:
      "This model cannot be used for text chat in Enigma. Choose a compatible model."
    case .unverified:
      "Unverified model. You can try this ID, but text-chat support and account access are not confirmed."
    }
  }
}

/// Endpoint compatibility and provider limits share exact, reviewed model IDs.
/// Model-list membership alone does not establish Responses API compatibility.
/// Sources, review date, and fallback ordering: docs/Cloud-Model-Selection.md.
enum CloudModelCapabilities {
  struct Metadata: Sendable {
    let ids: [String]
    let contextWindow: Int
    let maximumOutputTokens: Int
    var supportsCodex: Bool = false
  }

  // Prefer Luna, then smaller general-purpose models, before larger alternatives.
  // Aliases precede reviewed snapshots. Never infer support from a "gpt-" prefix.
  private static let openAITextModels: [Metadata] = [
    Metadata(ids: ["gpt-5.6-luna"], contextWindow: 1_050_000, maximumOutputTokens: 128_000, supportsCodex: true),
    Metadata(ids: ["gpt-5.4-mini", "gpt-5.4-mini-2026-03-17"], contextWindow: 400_000, maximumOutputTokens: 128_000),
    Metadata(ids: ["gpt-5-mini"], contextWindow: 400_000, maximumOutputTokens: 128_000),
    Metadata(ids: ["gpt-4.1-mini", "gpt-4.1-mini-2025-04-14"], contextWindow: 1_047_576, maximumOutputTokens: 32_768),
    Metadata(ids: ["gpt-4o-mini", "gpt-4o-mini-2024-07-18"], contextWindow: 128_000, maximumOutputTokens: 16_384),
    Metadata(ids: ["gpt-5.6-terra"], contextWindow: 1_050_000, maximumOutputTokens: 128_000, supportsCodex: true),
    Metadata(ids: ["gpt-5.6-sol", "gpt-5.6"], contextWindow: 1_050_000, maximumOutputTokens: 128_000, supportsCodex: true),
    Metadata(ids: ["gpt-4.1", "gpt-4.1-2025-04-14"], contextWindow: 1_047_576, maximumOutputTokens: 32_768),
    Metadata(ids: ["gpt-4o", "gpt-4o-2024-11-20", "gpt-4o-2024-08-06"], contextWindow: 128_000, maximumOutputTokens: 16_384),
  ]

  // These specialized families require other endpoints/modalities. This is only
  // a negative classification; unrecognized names remain unverified and usable.
  private static let nonChatFamilies = [
    "dall-e", "gpt-image", "chatgpt-image", "text-embedding", "sora",
    "tts", "whisper", "gpt-audio", "gpt-realtime", "gpt-transcribe",
    "gpt-live-transcribe", "gpt-4o-audio", "gpt-4o-mini-audio",
    "gpt-4o-realtime", "gpt-4o-mini-realtime", "gpt-4o-transcribe",
    "gpt-4o-mini-transcribe", "gpt-4o-mini-tts", "omni-moderation", "text-moderation",
  ]

  static func metadata(provider: CloudProviderID, modelID: String) -> Metadata? {
    let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    switch provider {
    case .openAI:
      return openAITextModels.first { $0.ids.contains(id) }
    case .chatGPT:
      // The API alias is not a verified Codex model identifier.
      return openAITextModels.first { $0.supportsCodex && $0.ids.first == id }
    case .gemini:
      return visionModelIDs(for: .gemini).contains(id)
        ? Metadata(ids: [id], contextWindow: 1_048_576, maximumOutputTokens: 4_096) : nil
    case .anthropic:
      return visionModelIDs(for: .anthropic).contains(id)
        ? Metadata(ids: [id], contextWindow: 200_000, maximumOutputTokens: 4_096) : nil
    }
  }

  static func compatibility(provider: CloudProviderID, modelID: String) -> CloudModelCompatibility {
    let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { return .unselected }
    if metadata(provider: provider, modelID: id) != nil { return .compatible }
    if provider == .openAI,
       nonChatFamilies.contains(where: { id == $0 || id.hasPrefix($0 + "-") }) {
      return .unsupported
    }
    return .unverified
  }

  static func chatModels(_ models: [CloudModel], for provider: CloudProviderID) -> [CloudModel] {
    var seen = Set<String>()
    let unique = models.filter {
      $0.provider == provider && !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && seen.insert($0.id).inserted
    }
    guard provider == .openAI else {
      // Anthropic Messages and Codex advertise their own chat models. Keep the
      // provider's order; OpenAI's general-purpose Models API needs our allowlist.
      return unique
    }
    let byID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
    return openAITextModels.flatMap(\.ids).compactMap { byID[$0] }
  }
}
