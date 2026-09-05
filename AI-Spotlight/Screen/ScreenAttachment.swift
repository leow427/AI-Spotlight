import AppKit

/// Full-resolution draft data. Neither originals nor sent-message previews enter chat storage.
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
