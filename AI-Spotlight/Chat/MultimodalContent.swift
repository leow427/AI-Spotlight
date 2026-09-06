import Foundation

struct MessageImagePart: Sendable, Equatable {
  let mimeType: String
  /// Raw base64, never a provider-specific URL. Created only at serialization time.
  let base64Data: String
}

enum MessageContentPart: Sendable, Equatable {
  case text(String)
  case image(MessageImagePart)
}

enum ScreenRequestError: LocalizedError, Equatable {
  case cloudUploadNotAllowed, textOnlyModel, invalidImage, invalidLocalEndpoint
  var errorDescription: String? {
    switch self {
    case .cloudUploadNotAllowed: "Screenshot upload is disabled. Use local vision or allow screenshots in Screen settings."
    case .textOnlyModel: "This model cannot process images. Select a model with image support in the normal model picker."
    case .invalidImage: "The screenshot payload is invalid. Please retake it."
    case .invalidLocalEndpoint: "Local vision must use a loopback address on this Mac."
    }
  }
}

enum ScreenRequestGuard {
  static func validateCloud(_ request: ChatRequest) throws {
    guard let image = request.image else { return }
    guard request.route.mode != .local, request.route.usesNetwork, request.allowsCloudImages else {
      throw ScreenRequestError.cloudUploadNotAllowed
    }
    guard let provider = CloudProviderID(rawValue: request.route.providerID),
          CloudModel(id: request.route.modelID, displayName: request.route.modelID, provider: provider).supportsVision else {
      throw ScreenRequestError.textOnlyModel
    }
    try validateImage(image)
  }

  static func validateImage(_ image: PreparedScreenImage) throws {
    guard ["image/jpeg", "image/png"].contains(image.mimeType), !image.data.isEmpty,
          image.data.count <= 10_000_000, image.pixelWidth > 0, image.pixelHeight > 0,
          max(image.pixelWidth, image.pixelHeight) <= ScreenImagePreprocessor.longestEdge else {
      throw ScreenRequestError.invalidImage
    }
  }
}

enum MultimodalSerialization {
  enum Format { case openAIChat, openAIResponses, anthropic, gemini, ollama }

  static func parts(text: String, image: PreparedScreenImage?) throws -> [MessageContentPart] {
    var parts = [MessageContentPart.text(text)]
    if let image {
      try ScreenRequestGuard.validateImage(image)
      parts.append(.image(MessageImagePart(mimeType: image.mimeType, base64Data: image.data.base64EncodedString())))
    }
    return parts
  }

  static func content(_ parts: [MessageContentPart], format: Format) -> [[String: Any]] {
    parts.map { part in
      switch part {
      case .text(let text):
        switch format {
        case .gemini: return ["text": text]
        case .openAIResponses: return ["type": "input_text", "text": text]
        default: return ["type": "text", "text": text]
        }
      case .image(let image):
        switch format {
        case .openAIChat:
          return ["type": "image_url", "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64Data)"]]
        case .openAIResponses:
          return ["type": "input_image", "image_url": "data:\(image.mimeType);base64,\(image.base64Data)"]
        case .anthropic:
          return ["type": "image", "source": ["type": "base64", "media_type": image.mimeType, "data": image.base64Data]]
        case .gemini:
          return ["inlineData": ["mimeType": image.mimeType, "data": image.base64Data]]
        case .ollama:
          return [:] // Native Ollama images belong in the message's images array below.
        }
      }
    }
  }

  static func messages(_ messages: [ChatMessage], image: PreparedScreenImage?, format: Format) throws -> [[String: Any]] {
    try messages.enumerated().map { index, message in
      let attached = index == messages.count - 1 && message.role == .user ? image : nil
      let parts = try parts(text: message.content, image: attached)
      switch format {
      case .gemini:
        return ["role": message.role == .assistant ? "model" : "user", "parts": content(parts, format: format)]
      case .ollama:
        var result: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        let images = parts.compactMap { part -> String? in
          if case .image(let image) = part { return image.base64Data }; return nil
        }
        if !images.isEmpty { result["images"] = images }
        return result
      default:
        // Keep the existing text-only wire format and place images only on the current turn.
        return ["role": message.role.rawValue, "content": attached == nil ? message.content as Any : content(parts, format: format)]
      }
    }
  }
}
