import AppKit
import XCTest
@testable import Enigma

final class ScreenOCRTests: XCTestCase {
  func testOrdersRowsTopToBottomThenLeftToRight() {
    let lines = [line("bottom", 0.6, 0.1, 0.1), line("right", 0.8, 0.6, 0.805), line("left", 1, 0.1, 0.8)]
    let result = ScreenOCRResult.assemble(lines)
    XCTAssertEqual(result.text, "left\nright\nbottom")
    XCTAssertEqual(result.confidence, 0.8, accuracy: 0.0001)
    XCTAssertEqual(ScreenOCRResult.assemble([]), .empty)
    XCTAssertEqual(ScreenOCRResult.assemble([line("  ", 1, 0, 0)]), .empty)
  }

  func testThresholdsCountNonWhitespaceCharacters() {
    XCTAssertFalse(ScreenOCRResult(text: String(repeating: "x", count: 39) + " \n\t", confidence: 1).isUsable)
    XCTAssertTrue(ScreenOCRResult(text: String(repeating: "x ", count: 40), confidence: 0.55).isUsable)
    XCTAssertFalse(ScreenOCRResult(text: String(repeating: "x", count: 40), confidence: 0.549).isUsable)
    XCTAssertFalse(ScreenOCRResult(text: String(repeating: "x", count: 40), confidence: .nan).isUsable)
  }

  @MainActor
  func testPreprocessingPreservesAspectRatioAndOriginalPixels() throws {
    for size in [NSSize(width: 3200, height: 1600), NSSize(width: 1000, height: 3000), NSSize(width: 200, height: 100)] {
      let image = fixture(size: size)
      let original = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
      let result = try ScreenImagePreprocessor.prepare(original)
      XCTAssertLessThanOrEqual(max(result.pixelWidth, result.pixelHeight), 1568)
      XCTAssertEqual(Double(result.pixelWidth) / Double(result.pixelHeight), Double(original.width) / Double(original.height), accuracy: 0.002)
      XCTAssertEqual(result.mimeType, "image/jpeg")
      XCTAssertEqual(Array(result.data.prefix(2)), [0xff, 0xd8])
      let decoded = try XCTUnwrap(NSBitmapImageRep(data: result.data))
      XCTAssertEqual(decoded.pixelsWide, result.pixelWidth)
      XCTAssertEqual(decoded.pixelsHigh, result.pixelHeight)
      XCTAssertEqual(original.width, Int(size.width))
    }
  }

  @MainActor
  func testNativeVisionReadsOriginalCodeAndTerminalFixture() async throws {
    let image = fixture(size: NSSize(width: 2200, height: 600), text: "let total_count = values.count\nerror: cannot find variable in scope\n/Users/example/project/main.swift:42")
    let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let result = try await ScreenOCRService().recognize(pixels)
    XCTAssertTrue(result.isUsable, result.text)
    XCTAssertTrue(result.text.contains("total_count"), result.text)
    XCTAssertTrue(result.text.contains("scope"), result.text)
    XCTAssertEqual(pixels.width, 2200)
  }

  private func line(_ text: String, _ confidence: Float, _ x: Double, _ y: Double) -> ScreenOCRLine {
    ScreenOCRLine(text: text, confidence: confidence, bounds: CGRect(x: x, y: y, width: 0.2, height: 0.04))
  }

  @MainActor
  private func fixture(size: NSSize, text: String = "") -> NSImage {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(in: NSRect(x: 40, y: 50, width: size.width - 80, height: size.height - 100), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 44, weight: .regular), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    return NSImage(cgImage: bitmap.cgImage!, size: size)
  }
}
