import AppKit
import XCTest
@testable import PrimaryAgent

/// Opt-in hardware smoke test. Never downloads models or changes the user's installed library.
@MainActor
final class ScreenNativeSmokeTests: XCTestCase {
  func testGGUFAndProjectorThroughProductionLocalVisionEngine() async throws {
    let configURL = URL(fileURLWithPath: "/tmp/AI-Spotlight-Vision-Smoke.json")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      throw XCTSkip("Optional real-model test: provide /tmp/AI-Spotlight-Vision-Smoke.json as documented in docs/Screen-Skill.md.")
    }
    struct Config: Decodable { let model: URL; let projector: URL; let server: URL }
    let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
    let libraryURL = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenNativeSmoke-\(UUID())")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let source = LocalModel(id: "smoke-vision", displayName: "Temporary vision smoke test", fileURL: config.model,
      visionConfiguration: LocalVisionConfiguration(projectorURL: config.projector, serverExecutableURL: config.server))
    let installed = try LocalModelInstallationStore(modelsDirectory: libraryURL).install(source)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 400).fill()
    NSColor.red.setFill(); NSBezierPath(ovalIn: NSRect(x: 60, y: 100, width: 160, height: 160)).fill()
    NSColor.blue.setFill(); NSRect(x: 350, y: 100, width: 160, height: 160).fill()
    NSGraphicsContext.restoreGraphicsState()
    let image = try ScreenImagePreprocessor.prepare(XCTUnwrap(bitmap.cgImage))
    var answer = ""
    let start = Date()
    for try await text in LlamaServerVisionEngine().stream(
      messages: [ChatMessage(role: .user, content: "Describe the shapes and colors in this image in one sentence.")], image: image, model: installed) {
      answer += text
    }
    XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    let report = "Production llama-server vision smoke test\nElapsed: \(Date().timeIntervalSince(start)) s\nAnswer: \(answer)\n"
    try report.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Vision-Smoke-Result.txt"), atomically: true, encoding: .utf8)
    let attachment = XCTAttachment(string: report)
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
