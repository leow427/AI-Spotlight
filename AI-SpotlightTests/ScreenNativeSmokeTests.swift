import AppKit
import Combine
import SwiftUI
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

/// Opt-in installed-model matrix with synthetic screenshots. Fixed evidence is
/// the default; liveSearch explicitly enables real Brave requests. Assertions
/// cover the pipeline and basic content, not complete factual answer accuracy.
@MainActor
final class ScreenSearchNativeSmokeTests: XCTestCase {
  func testReadingQueryAndAnswerWithInstalledModels() async throws {
    let configURL = URL(fileURLWithPath: "/tmp/AI-Spotlight-Screen-Search-Smoke.json")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      throw XCTSkip("Opt-in real-model check: see docs/Screen-Skill.md.")
    }
    struct Config: Decodable { let modelsDirectory: URL; let visionModelID: String; let useTextModel: Bool; let liveSearch: Bool? }
    let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
    let store = LocalModelInstallationStore(modelsDirectory: config.modelsDirectory)
    let textModel = try XCTUnwrap(store.installedModel())
    let visionModel = try XCTUnwrap(store.installedModels().first { $0.id == config.visionModelID })
    let log = NativeSmokeLog()
    let engine = NativeSmokeEngine(base: LlamaCPPModelEngine(installationStore: store), log: log)
    let directory = FileManager.default.temporaryDirectory.appending(path: "ScreenSearchNative-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    var reports: [String] = []
    let cases = [
      ("serendipity", "Can you look up what this word means from the dictionary?", "serendipity", "dictionary definition", "Serendipity means finding something valuable or pleasant by chance.", "https://dictionary.cambridge.org/dictionary/english/serendipity"),
      ("Memory: 59.7 MB", "How much RAM am I using, and can you search whether that is a lot?", "59.7", "RAM memory usage", "Memory pressure indicates whether a Mac is using memory efficiently. An individual process's memory figure alone does not describe total RAM use or memory pressure.", "https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac"),
      ("serendipity", "What color is the word, and can you look up its dictionary definition?", "serendipity", "dictionary definition", "Serendipity means finding something valuable or pleasant by chance.", "https://dictionary.cambridge.org/dictionary/english/serendipity"),
      ("ubiquitous", "Find a dictionary definition of the word shown here and explain it simply.", "ubiquitous", "dictionary definition", "Ubiquitous describes something that is present or found everywhere.", "https://dictionary.cambridge.org/dictionary/english/ubiquitous"),
      ("Memory: 57 MB", "Is this a lot of RAM? Please look it up.", "57", "RAM memory usage", "Memory pressure indicates whether a Mac is using memory efficiently. The amount used by one process is not the computer's total memory usage.", "https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac"),
      ("HTTP 404", "What does this mean? Search for an explanation.", "404", "HTTP error meaning", "HTTP 404 Not Found means the server cannot find the requested resource. Check the URL for mistakes or whether the resource was moved or removed.", "https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/404"),
      ("HTTP 429", "Look up what this error means and how to fix it.", "429", "HTTP error fix", "HTTP 429 Too Many Requests means the client has sent too many requests in a given time. A Retry-After header can indicate how long to wait before retrying.", "https://www.rfc-editor.org/rfc/rfc6585#section-4"),
    ]
    for (visible, prompt, subject, intent, excerpt, url) in cases {
      let image = try fixtureImage(text: visible)
      var screenshot = try ScreenAttachment(image: image)
      let ocr = try await ScreenOCRService().recognize(XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
      screenshot.ocrText = ocr.text
      screenshot.ocrConfidence = ocr.confidence
      let search = NativeSmokeSearch(result: WebSearchResult(source: WebSearchSource(title: intent, url: URL(string: url)!), snippets: [excerpt]), live: config.liveSearch == true)
      log.clear()
      let chat = LocalChatViewModel(engine: engine, visionEngine: NativeSmokeVision(log: log), webSearch: search,
        sessionStore: ChatSessionStore(applicationSupportDirectory: directory.appending(path: UUID().uuidString)))
      await chat.refreshInstalledModel()
      var phases: [String] = []
      let done = expectation(description: "\(visible) finishes")
      let token = chat.$state.dropFirst().sink { state in
        if phases.last != String(describing: state) { phases.append(String(describing: state)) }
        switch state {
        case .idle, .failed: done.fulfill()
        default: break
        }
      }
      let start = Date()
      let decision = config.useTextModel
        ? ScreenRoutingPolicy.decide(ScreenRoutingPolicy.Request(prompt: prompt, ocr: ocr, mode: .local,
          localText: textModel.screenModel, localVision: [visionModel.screenModel]))
        : .vision(visionModel.screenModel)
      chat.submitScreen(prompt, attachment: screenshot, decision: decision, selectedMode: .local,
        searchEnabled: true, searchTextModel: config.useTextModel ? textModel.screenModel : nil, cloudUploadAllowed: { false })
      await fulfillment(of: [done], timeout: 180)
      token.cancel()
      if chat.isBusy {
        chat.stopStreaming()
        throw WebSearchError.unavailable
      }
      let queries = await search.queries
      let answer = chat.messages.last?.content ?? ""
      reports.append("Search: \(config.liveSearch == true ? "live Brave" : "fixed evidence")\nModel outputs: \(log.outputs)\nScreen: \(visible)\nOCR: \(ocr.text)\nQuestion: \(prompt)\nQueries: \(queries)\nPhases: \(phases)\nSeconds: \(Date().timeIntervalSince(start))\nAnswer: \(answer)\n")
      try reports.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Screen-Search-Smoke-Result.txt"), atomically: true, encoding: .utf8)
      XCTAssertEqual(chat.state, .idle)
      XCTAssertEqual(queries.count, 1)
      XCTAssertTrue(queries.first?.localizedCaseInsensitiveContains(subject) == true)
      if visible == "HTTP 429" { XCTAssertFalse(queries.first?.contains("500") == true, "Do not invent another error code") }
      XCTAssertGreaterThan(queries.first?.split(whereSeparator: \.isWhitespace).count ?? 0, 2, "The query must retain the question's intent, not just transcribe.")
      XCTAssertGreaterThan(answer.count, visible.count + 30, "The answer must go beyond reading the screen.")
      let retrieved = await search.sources
      XCTAssertFalse(retrieved.isEmpty)
      // Source links are part of the message UI even when a small model omits
      // inline URLs. Verify that rendering, not a probabilistic prose format.
      let message = try XCTUnwrap(chat.messages.last)
      let renderer = ImageRenderer(content: LocalMessageView(message: message).padding(20).frame(width: 700)
        .background(Color.white).environment(\.colorScheme, .light))
      renderer.scale = 2
      let rendered = try XCTUnwrap(renderer.cgImage)
      let renderedText = try await ScreenOCRService().recognize(rendered).text.lowercased()
      XCTAssertTrue(renderedText.contains("sources") && renderedText.contains("brave search"))
      let png = try XCTUnwrap(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
      let preview = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      preview.name = "Screen search · \(visible)"
      preview.lifetime = .keepAlways
      add(preview)
      if visible == "serendipity" { XCTAssertTrue(answer.lowercased().contains("chance") || answer.lowercased().contains("accident")) }
      if visible == "ubiquitous" { XCTAssertTrue(answer.lowercased().contains("everywhere")) }
      if visible.hasPrefix("Memory:") { XCTAssertTrue(answer.contains(subject)); XCTAssertTrue(answer.lowercased().contains("memory") || answer.lowercased().contains("ram")) }
      if visible == "HTTP 429" { XCTAssertTrue(answer.lowercased().contains("too many") || answer.lowercased().contains("rate limit")) }
      if visible == "HTTP 404" { XCTAssertTrue(answer.lowercased().contains("not found") || answer.lowercased().contains("cannot find")) }
      XCTAssertTrue(chat.messages.last?.searchSources?.allSatisfy { retrieved.contains($0) } == true)
      XCTAssertFalse(chat.messages.last?.searchSources?.isEmpty ?? true)
      await engine.unload()
    }
    let attachment = XCTAttachment(string: reports.joined(separator: "\n"))
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func fixtureImage(text: String) throws -> NSImage {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 160,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 640, height: 160).fill()
    (text as NSString).draw(at: NSPoint(x: 24, y: 54), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    return NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: NSSize(width: 640, height: 160))
  }
}

private actor NativeSmokeSearch: WebSearchProvider {
  nonisolated let result: WebSearchResult
  private let live: Bool
  private(set) var queries: [String] = []
  private(set) var sources: [WebSearchSource] = []
  init(result: WebSearchResult, live: Bool) { self.result = result; self.live = live }
  func search(_ query: String, maximumTokens: Int) async throws -> [WebSearchResult] {
    queries.append(query)
    let results = live ? try await BraveSearchClient().search(query, maximumTokens: maximumTokens) : [result]
    sources = results.map(\.source)
    return results
  }
}

private final class NativeSmokeLog: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  var outputs: [String] { lock.withLock { values } }
  func clear() { lock.withLock { values.removeAll() } }
  func record(_ value: String) { lock.withLock { values.append(value) } }
  func wrap(_ stream: AsyncThrowingStream<String, Error>, label: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var output = ""
        do {
          for try await part in stream { output += part; continuation.yield(part) }
          record(label + ": " + output)
          continuation.finish()
        } catch { record(label + ": " + output); continuation.finish(throwing: error) }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }
}

private struct NativeSmokeVision: LocalVisionServing {
  let log: NativeSmokeLog
  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) -> AsyncThrowingStream<String, Error> {
    log.wrap(LlamaServerVisionEngine().stream(messages: messages, image: image, model: model), label: "Vision")
  }
}

private struct NativeSmokeEngine: LocalModelEngine {
  let base: LlamaCPPModelEngine
  let log: NativeSmokeLog
  func installedModel() async -> LocalModel? { await base.installedModel() }
  func installedModels() async -> [LocalModel] { await base.installedModels() }
  func prepare(_ request: LocalModelRequest) async throws -> PreparedConversation { try await base.prepare(request) }
  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> { log.wrap(base.stream(request), label: "Text") }
  func unload() async { await base.unload() }
  func install(_ model: LocalModel) throws { throw LocalInferenceError.invalidModelFile }
  func selectModel(id: String) throws { throw LocalInferenceError.unknownInstalledModel }
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) throws -> LocalModel { throw LocalInferenceError.noModelInstalled }
}
