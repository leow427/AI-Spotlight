import AppKit

/// Draft-only data. Deliberately not Codable: screenshot pixels never enter chat storage.
@MainActor
struct ScreenAttachment: Identifiable {
  enum Source: String { case screenRegion }
  enum Status: String { case captured = "Screenshot", reading = "Reading text…", localOCR = "Local OCR", vision = "Vision" }
  let id = UUID()
  let originalImage: NSImage
  let mimeType = "image/png"
  let pixelWidth: Int
  let pixelHeight: Int
  var ocrText = ""
  var ocrConfidence: Float = 0
  let source = Source.screenRegion
  var status = Status.captured
  var routingDecision: ScreenRoutingPolicy.Decision?
  let createdAt = Date()

  init(image: NSImage) throws {
    guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          pixels.width > 0, pixels.height > 0 else { throw ScreenCaptureError.invalidImage }
    originalImage = image
    pixelWidth = pixels.width
    pixelHeight = pixels.height
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
