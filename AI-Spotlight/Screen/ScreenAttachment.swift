import AppKit

/// Full-resolution draft data. Neither originals nor sent-message previews enter chat storage.
@MainActor
struct ScreenAttachment: Identifiable {
  enum Source: String { case screenRegion, fullDesktop }
  enum Status: String { case captured = "Screenshot", reading = "Reading text…", localOCR = "Local OCR", vision = "Vision" }
  let id = UUID()
  let originalImage: NSImage
  let mimeType = "image/png"
  let pixelWidth: Int
  let pixelHeight: Int
  var ocrText = ""
  var ocrConfidence: Float = 0
  let source: Source
  var status = Status.captured
  var routingDecision: ScreenRoutingPolicy.Decision?
  let createdAt = Date()

  init(image: NSImage, source: Source = .screenRegion) throws {
    self.source = source
    guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          pixels.width > 0, pixels.height > 0 else { throw ScreenCaptureError.invalidImage }
    originalImage = image
    pixelWidth = pixels.width
    pixelHeight = pixels.height
  }

  /// A bounded Retina preview retained only for the current app session.
  func makeMessagePreview() -> Data? {
    guard let pixels = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let scale = min(1, 240.0 / Double(pixels.width), 192.0 / Double(pixels.height))
    let width = max(1, Int((Double(pixels.width) * scale).rounded()))
    let height = max(1, Int((Double(pixels.height) * scale).rounded()))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let thumbnail = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:])
  }
}

enum ScreenCommand {
  static func remainder(in prompt: String) -> String? {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.lowercased().hasPrefix("/screen") else { return nil }
    let remainder = text.dropFirst(7)
    guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
    return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Resolve recognized commands anywhere in the draft, once, at submission.
struct ComposerCommands: Equatable {
  let prompt: String
  let screen: Bool
  let search: Bool
  let snapshot: Bool
  let think: Bool

  init(_ draft: String) {
    let commands = Set(SlashCommand.tokens(in: draft).map(\.command))
    prompt = SlashCommand.removing(Set(SlashCommand.allCases), from: draft)
    screen = commands.contains(.screen) || commands.contains(.snapshot)
    search = commands.contains(.search)
    snapshot = commands.contains(.snapshot)
    think = commands.contains(.think)
  }

  var submissionPrompt: String { (think ? "/think " : "") + prompt }
  var captureDraft: String { (snapshot ? "/snapshot" : "/screen") + (submissionPrompt.isEmpty ? "" : " " + submissionPrompt) }
}

enum ThinkCommand {
  static let guidance = "Think carefully before answering. Check assumptions, compare possible solutions, and verify the result. Return the answer with a concise explanation."

  static func remainder(in prompt: String, command: String = "/think") -> String? {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.lowercased().hasPrefix(command) else { return nil }
    let rest = text.dropFirst(command.count)
    guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
    return rest.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func message(_ prompt: String) -> ChatMessage {
    let enabled = SlashCommand.tokens(in: prompt).contains { $0.command == .think }
    var message = ChatMessage(role: .user, content: enabled ? SlashCommand.removing([.think], from: prompt) : prompt)
    message.extendedThinking = enabled ? true : nil
    return message
  }

  static func enabled(in messages: [ChatMessage]) -> Bool {
    messages.last(where: { $0.role == .user })?.extendedThinking == true
  }

  static func localOutputTokens(_ messages: [ChatMessage]) -> Int {
    enabled(in: messages) ? 2_048 : 512
  }
}
