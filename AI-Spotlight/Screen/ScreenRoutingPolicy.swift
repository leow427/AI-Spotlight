import Foundation

struct ModelInputCapabilities: Codable, Sendable, Equatable {
  let supportsText: Bool
  let supportsVision: Bool
  static let textOnly = ModelInputCapabilities(supportsText: true, supportsVision: false)
  static let textAndVision = ModelInputCapabilities(supportsText: true, supportsVision: true)
}

struct ScreenModel: Sendable, Equatable {
  let id: String
  let provider: String
  let isLocal: Bool
  let capabilities: ModelInputCapabilities
  var visionProjectorPath: String? = nil
  var supportsText: Bool { capabilities.supportsText }
  var supportsVision: Bool { capabilities.supportsVision }
  var canUseVision: Bool {
    supportsVision && (provider != "llama.cpp" || visionProjectorPath != nil)
  }
  var route: Route {
    route(searchEnabled: false)
  }
  func route(searchEnabled: Bool) -> Route {
    Route(mode: isLocal ? .local : .cloud, providerID: provider, modelID: id, usesNetwork: !isLocal || searchEnabled)
  }
}

struct LocalVisionConfiguration: Codable, Sendable, Equatable {
  let projectorURL: URL
  let serverExecutableURL: URL
  var contextWindow: Int = 8192
  var managedRuntimeDirectory: URL? = nil
  // Absent in older installations and manually imported packages.
  var packageRevision: String? = nil
}

extension LocalModel {
  var supportsText: Bool { true }
  var supportsVision: Bool { visionConfiguration != nil }
  var isLocal: Bool { true }
  var provider: String { supportsVision ? "llama.cpp" : "local" }
  var visionProjectorPath: String? { visionConfiguration?.projectorURL.path }
  var screenModel: ScreenModel {
    ScreenModel(id: id, provider: provider, isLocal: true,
                capabilities: ModelInputCapabilities(supportsText: supportsText, supportsVision: supportsVision),
                visionProjectorPath: visionProjectorPath)
  }
}

extension LocalModelDescriptor {
  var supportsText: Bool { true }
  var supportsVision: Bool { projector != nil && runtimeBuild == LocalVisionRuntime.build }
  var isLocal: Bool { true }
  var provider: String { "local" }
  var visionProjectorPath: String? { nil }
}

extension CloudModel {
  var supportsText: Bool { CloudModelCapabilities.compatibility(provider: provider, modelID: id).allowsSending }
  var supportsVision: Bool { CloudModelCapabilities.visionModelIDs(for: provider).contains(id) }
  var isLocal: Bool { false }
  var visionProjectorPath: String? { nil }
  var screenModel: ScreenModel {
    ScreenModel(id: id, provider: provider.rawValue, isLocal: false,
                capabilities: ModelInputCapabilities(supportsText: supportsText, supportsVision: supportsVision))
  }
}

extension CloudModelCapabilities {
  /// Exact reviewed IDs. Unknown/manual IDs never acquire vision from their names.
  static func visionModelIDs(for provider: CloudProviderID) -> [String] {
    switch provider {
    case .openAI:
      ["gpt-4.1-mini", "gpt-4.1-mini-2025-04-14", "gpt-4.1", "gpt-4.1-2025-04-14",
       "gpt-4o-mini", "gpt-4o-mini-2024-07-18", "gpt-4o", "gpt-4o-2024-11-20", "gpt-4o-2024-08-06",
       "gpt-5-mini", "gpt-5.4-mini", "gpt-5.4-mini-2026-03-17"]
    case .anthropic:
      ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5", "claude-haiku-4-5-20251001",
       "claude-sonnet-4-5", "claude-sonnet-4-5-20250929", "claude-sonnet-4-20250514",
       "claude-opus-4-20250514", "claude-3-7-sonnet-20250219", "claude-3-5-haiku-20241022"]
    case .gemini:
      ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite"]
    case .chatGPT:
      [] // The subscription adapter currently accepts text only.
    }
  }
}

enum ScreenRoutingPolicy {
  static let screenshotUploadDisabledMessage = "Screenshot upload is disabled. Enable it in Screen settings or select a local text-and-image model. Your draft has been kept."

  struct Request: Sendable {
    let prompt: String
    let ocr: ScreenOCRResult
    let mode: ChatMode
    var localText: ScreenModel? = nil
    var cloudText: ScreenModel? = nil
    var autoRoute: Route? = nil
    var allowCloudScreenshots = false
    var hasExplainedCloudPermission = false
    var isOffline = false
  }

  enum Decision: Equatable, Sendable {
    case text(ScreenModel)
    case vision(ScreenModel)
    case needsCloudPermission
    case blocked(String)

    var model: ScreenModel? {
      switch self { case .text(let model), .vision(let model): model; default: nil }
    }
    var sendsImage: Bool { if case .vision = self { true } else { false } }
    var status: String {
      switch self {
      case .text: "Local OCR"
      case .vision(let model): model.isLocal ? "Vision · Local" : "Vision · Cloud"
      case .needsCloudPermission: "Screenshot upload permission needed"
      case .blocked(let reason): reason
      }
    }
  }

  static func hasConfidentTextForLookup(prompt: String, ocr: ScreenOCRResult) -> Bool {
    let textLookup = prompt.lowercased().range(of: #"\b(words?|terms?|dictionary|definitions?|meaning|means?|text|ram|memory|errors?|code)\b"#,
      options: .regularExpression) != nil
    return textLookup && (1...40).contains(ocr.nonWhitespaceCharacterCount)
      && ocr.confidence.isFinite && ocr.confidence >= 0.85
  }

  static func requiresVision(prompt: String, ocr: ScreenOCRResult) -> Bool {
    // A confidently read word/value/code is enough for a text lookup. Explicit
    // visual questions below still require the image.
    guard ocr.isUsable || hasConfidentTextForLookup(prompt: prompt, ocr: ocr) else { return true }
    let text = prompt.lowercased()
    // Text extraction is meaningful even when the source is a chart or photo.
    let extraction = ["transcribe", "extract the text", "read the text", "copy the text", "ocr"]
    let visual = #"\b(diagrams?|charts?|graphs?|photos?|photographs?|colors?|colours?|layout|appearance|alignment|positions?|spatial|shapes?|circles?|squares?|triangles?|arrows?|above|below|left|right|objects?|icons?|buttons?|flowcharts?)\b|what.*look like|visual (bug|issue)|where (is|are)|which (button|object)|overlap|cropped|cut off"#
    if extraction.contains(where: text.contains),
       text.range(of: #"\b(color|colour|position|layout|where|visual)\b"#, options: .regularExpression) == nil { return false }
    return text.range(of: visual, options: .regularExpression) != nil
  }

  static func decide(_ request: Request) -> Decision {
    let local = request.localText.flatMap { $0.isLocal && $0.supportsText ? $0 : nil }
    let cloud = request.cloudText.flatMap { !$0.isLocal && $0.supportsText && !request.isOffline ? $0 : nil }
    let selected: ScreenModel?
    switch request.mode {
    case .local: selected = local
    case .cloud: selected = cloud
    case .auto: selected = request.autoRoute?.mode == .cloud ? (cloud ?? local) : (local ?? cloud)
    }
    let needsImage = requiresVision(prompt: request.prompt, ocr: request.ocr)
    guard let selected else { return .blocked("Choose an available model for this mode. Your screenshot and draft have been kept.") }
    if !needsImage { return .text(selected) }
    if selected.isLocal {
      if selected.canUseVision { return .vision(selected) }
      return .blocked("The selected local model is text-only. Install and select a recommended text-and-image package in Local Models. Your screenshot and draft have been kept.")
    }
    if selected.canUseVision && request.allowCloudScreenshots && request.hasExplainedCloudPermission {
      return .vision(selected)
    }
    // Consent is a constraint on normal Auto routing. Its only local fallback is
    // the ordinary selected model, never another installed vision package.
    if request.mode == .auto, let local, local.canUseVision { return .vision(local) }
    if selected.canUseVision && !request.hasExplainedCloudPermission { return .needsCloudPermission }
    if !selected.canUseVision { return .blocked("The selected cloud model cannot receive images. Choose a model with image support in the normal model picker. Your draft has been kept.") }
    return .blocked(screenshotUploadDisabledMessage)
  }
}
