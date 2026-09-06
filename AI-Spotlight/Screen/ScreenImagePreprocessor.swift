import AppKit
import ImageIO
import UniformTypeIdentifiers

struct PreparedScreenImage: Sendable, Equatable {
  let data: Data
  let mimeType: String
  let pixelWidth: Int
  let pixelHeight: Int
}

enum ScreenImagePreprocessor {
  static let longestEdge = 1_568
  static let jpegQuality = 0.85

  static func prepare(_ original: CGImage) throws -> PreparedScreenImage {
    let scale = min(1, Double(longestEdge) / Double(max(original.width, original.height)))
    let width = max(1, Int((Double(original.width) * scale).rounded(.down)))
    let height = max(1, Int((Double(original.height) * scale).rounded(.down)))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw ScreenCaptureError.invalidImage
    }
    // JPEG has no alpha; composite transparent areas onto white.
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { throw ScreenCaptureError.invalidImage }
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw ScreenCaptureError.invalidImage
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ScreenCaptureError.invalidImage }
    return PreparedScreenImage(data: bytes as Data, mimeType: "image/jpeg", pixelWidth: width, pixelHeight: height)
  }
}
