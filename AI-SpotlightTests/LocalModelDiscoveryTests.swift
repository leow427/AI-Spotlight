import AppKit
import SwiftUI
import XCTest
@testable import Enigma

@MainActor
final class LocalModelDiscoveryTests: XCTestCase {
  func testSearchEncodesInputAndIncludesSecondaryModalityTags() throws {
    let query = ModelDiscoveryQuery(search: "  google/gemma & Q4  ", scope: .audio)
    XCTAssertFalse(query.tasks.contains { $0.id == "image-text-to-text" })
    XCTAssertTrue(query.tasks.contains { $0.id == "any-to-any" })
    XCTAssertTrue(query.tasks.contains { $0.id == "automatic-speech-recognition" })
    let url = query.url(for: try XCTUnwrap(query.tasks.first))
    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(items.first { $0.name == "search" }?.value, "google/gemma & Q4")
    XCTAssertNotNil(items.first { $0.name == "filter" })
    XCTAssertNil(items.first { $0.name == "pipeline_tag" })
    XCTAssertEqual(items.first { $0.name == "limit" }?.value, "20")
    let all = ModelDiscoveryQuery().tasks
    XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    XCTAssertTrue(all.contains { $0.id == "image-text-to-text" })
    XCTAssertTrue(all.contains { $0.id == "text-to-speech" })
  }

  func testDecodingRetainsAudioTagsAlongsideVisionAndRejectsInvalidModelLinks() throws {
    let data = Data(#"[{"id":"org/omni","pipeline_tag":"image-text-to-text","tags":["audio-text-to-text","gguf","license:apache-2.0"],"downloads":20},{"id":"org/minimal"},{"id":"../../evil"},{"id":"org/model?redirect=evil"}]"#.utf8)
    let page = try HuggingFaceModelClient.decode(data, link: nil, currentURL: firstURL)
    XCTAssertEqual(page.models.map(\.id), ["org/omni", "org/minimal"])
    XCTAssertEqual(page.models[0].tasks.map(\.id), ["image-text-to-text", "audio-text-to-text"])
    XCTAssertEqual(page.models[0].license, "apache-2.0")
    XCTAssertTrue(page.models[0].isGGUF)
    XCTAssertEqual(page.models[0].url.absoluteString, "https://huggingface.co/org/omni")
    XCTAssertNil(page.models[1].downloads)
  }

  func testPaginationFollowsLinkAndPreservesTheSearch() throws {
    let next = nextURL(firstURL)
    let page = try HuggingFaceModelClient.decode(Data("[]".utf8),
      link: "<\(firstURL)>; rel=\"first\", <\(next)>; rel=\"next\"", currentURL: firstURL)
    XCTAssertEqual(page.nextURL, next)
    for invalid in [
      "https://example.com/api/models", "http://huggingface.co/api/models",
      "https://huggingface.co/api/models/org/private", "https://name@huggingface.co/api/models",
      "https://huggingface.co:443/api/models", "https://huggingface.co/api/models#fragment",
      firstURL.absoluteString,
      next.absoluteString.replacingOccurrences(of: "image-text-to-text", with: "text-generation"),
    ] {
      XCTAssertThrowsError(try HuggingFaceModelClient.decode(Data("[]".utf8),
        link: "<\(invalid)>; rel=\"next\"", currentURL: firstURL), invalid)
    }
    XCTAssertThrowsError(try HuggingFaceModelClient.decode(Data("not json".utf8), link: nil, currentURL: firstURL))
    XCTAssertThrowsError(try HuggingFaceModelClient.decode(
      Data(repeating: 32, count: HuggingFaceModelClient.maximumResponseBytes + 1), link: nil, currentURL: firstURL))
  }

  func testAllTasksArePagedWithoutDuplicatesOrACatalogSizeLimit() async {
    let recorder = DiscoveryRequestRecorder()
    let model = LocalModelDiscovery { url in
      await recorder.record(url)
      let isNext = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cursor" } == true
      if isNext { return HuggingFaceModelPage(models: [HuggingFaceModelListing(id: "org/second", downloads: 5)]) }
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      components.queryItems?.append(URLQueryItem(name: "cursor", value: "page-two"))
      return HuggingFaceModelPage(models: [HuggingFaceModelListing(id: "org/first", downloads: 10)], nextURL: components.url)
    }
    await model.search(ModelDiscoveryQuery())
    XCTAssertEqual(model.models.map(\.id), ["org/first"])
    XCTAssertTrue(model.hasMore)
    XCTAssertFalse(model.isLoading)
    let firstCount = await recorder.urls.count
    XCTAssertEqual(firstCount, HuggingFaceTask.all.count)
    await model.loadMore()
    XCTAssertEqual(model.models.map(\.id), ["org/first", "org/second"])
    XCTAssertFalse(model.hasMore)
    let finalCount = await recorder.urls.count
    XCTAssertEqual(finalCount, HuggingFaceTask.all.count * 2)
  }

  func testPartialFailureKeepsResultsAndRetriesOnlyFailedTask() async {
    let recorder = DiscoveryRequestRecorder()
    let model = LocalModelDiscovery { url in
      let attempt = await recorder.record(url)
      if url.query?.contains("audio-text-to-text") == true && attempt == 1 {
        throw ModelDiscoveryError.rateLimited
      }
      return HuggingFaceModelPage(models: [HuggingFaceModelListing(id: "org/available")])
    }
    await model.search(ModelDiscoveryQuery(scope: .audio))
    XCTAssertEqual(model.models.count, 1)
    XCTAssertEqual(model.failedTaskCount, 1)
    XCTAssertTrue(model.hasMore)
    XCTAssertTrue(model.notice?.contains("too many requests") == true)
    let before = await recorder.urls.count
    await model.retry()
    let after = await recorder.urls.count
    XCTAssertEqual(after, before + 1)
    XCTAssertEqual(model.failedTaskCount, 0)
    XCTAssertNil(model.notice)
    XCTAssertFalse(model.hasMore)
  }

  func testNewSearchIgnoresAnOlderResponseEvenIfTransportDoesNotCancel() async {
    let oldStarted = expectation(description: "Old search started")
    let gate = DiscoveryPageGate()
    let model = LocalModelDiscovery { url in
      if url.query?.contains("search=old") == true {
        return await gate.wait { oldStarted.fulfill() }
      }
      return HuggingFaceModelPage(models: [HuggingFaceModelListing(id: "org/new")])
    }
    let old = Task { await model.search(ModelDiscoveryQuery(search: "old", taskID: "image-text-to-text")) }
    await fulfillment(of: [oldStarted], timeout: 2)
    await model.search(ModelDiscoveryQuery(search: "new", taskID: "image-text-to-text"))
    await gate.finish()
    await old.value
    XCTAssertEqual(model.models.map(\.id), ["org/new"])
    XCTAssertFalse(model.isLoading)
    XCTAssertNil(model.notice)
  }

  func testEmptyResultsAndOfflineFailureAreDifferentStates() async {
    let empty = LocalModelDiscovery { _ in HuggingFaceModelPage(models: []) }
    await empty.search(ModelDiscoveryQuery(taskID: "image-text-to-text"))
    XCTAssertTrue(empty.models.isEmpty)
    XCTAssertNil(empty.notice)
    XCTAssertFalse(empty.hasMore)
    let offline = LocalModelDiscovery { _ in throw URLError(.notConnectedToInternet) }
    await offline.search(ModelDiscoveryQuery(taskID: "image-text-to-text"))
    XCTAssertTrue(offline.models.isEmpty)
    XCTAssertNotNil(offline.notice)
    XCTAssertTrue(offline.hasMore)
    XCTAssertFalse(offline.isLoading)
  }

  func testFeaturedGemmaIsTheVerifiedQ4MoEVisionPackageAndHonorsMemoryAdmission() throws {
    let model = try XCTUnwrap(LocalModelManifest.bundled.models.first { $0.id == LocalModelDiscovery.featuredModelID })
    try model.validate()
    XCTAssertEqual(model.inferenceProfile, .gemma4A4B)
    XCTAssertEqual(model.quantization, "Q4_K_M")
    XCTAssertEqual(model.huggingFaceRepositoryID, "bartowski/google_gemma-4-26B-A4B-it-GGUF")
    XCTAssertEqual(model.checksumSHA256, "a07f72221e8e3f77455ab0d7f7652d01a9f63c262b954aa6932a53275a0e895a")
    XCTAssertEqual(model.projector?.checksumSHA256, "41cdabd1e8066e983ee6c288eb0117777376223ee0279cadcd67b2295e4d975f")
    XCTAssertTrue(LocalModelCompatibility.supports(model))
    XCTAssertTrue(model.supportsVision)
    XCTAssertEqual(model.modelSupportsAudio, false)
    let limited = LocalModelSelector.assess(model, hardware: hardware(memory: 16))
    XCTAssertTrue(limited.canInstall)
    XCTAssertTrue(limited.permitsMemoryOverride)
    XCTAssertFalse(limited.fit.canRun)
    XCTAssertTrue(LocalModelSelector.assess(model, hardware: hardware(memory: 128)).canInstall)
  }

  func testDiscoverRendersWithOfflineFixturesInBothAppearances() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "DiscoveryTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let hardware = hardware(memory: 16)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in hardware })
    await advisor.start(installedModels: [], presentOnboarding: false)
    let chat = LocalChatViewModel(engine: DiscoveryTestEngine(), modelAdvisor: advisor,
      sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    let fixture = HuggingFaceModelListing(id: "google/gemma-4-26B-A4B-it",
      pipelineTag: "image-text-to-text", tags: ["license:apache-2.0"], downloads: 120_000, likes: 1_200)
    for scheme in [ColorScheme.dark, .light] {
      let discovery = LocalModelDiscovery { _ in HuggingFaceModelPage(models: [fixture]) }
      await discovery.search(ModelDiscoveryQuery())
      let view = NSHostingView(rootView: LocalModelDiscoveryView(discovery: discovery, advisor: advisor, chat: chat)
        .frame(width: 560, height: 850).naturePresentation())
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 850),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      window.contentView = view
      view.layoutSubtreeIfNeeded()
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      repeat { await Task.yield(); view.layoutSubtreeIfNeeded() }
      while (discovery.isLoading || discovery.models.isEmpty) && ContinuousClock.now < deadline
      XCTAssertFalse(discovery.isLoading)
      XCTAssertEqual(discovery.models.map(\.id), [fixture.id])
      XCTAssertEqual(view.fittingSize, NSSize(width: 560, height: 850))
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "/tmp/Enigma-Discover-\(scheme == .dark ? "dark" : "light").png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "Discover · \(scheme == .dark ? "dark" : "light")"
      attachment.lifetime = .keepAlways
      add(attachment)
      window.contentView = nil
    }
  }

  private var firstURL: URL {
    ModelDiscoveryQuery(taskID: "image-text-to-text").url(for: HuggingFaceTask.all[0])
  }

  private func nextURL(_ url: URL) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems?.append(URLQueryItem(name: "cursor", value: "opaque+/="))
    return components.url!
  }

  private func hardware(memory: Int64) -> LocalHardwareProfile {
    LocalHardwareProfile(physicalMemory: memory * LocalHardwareProfile.gib,
      isAppleSilicon: true, hasMetal: true, hasUnifiedMemory: true, chip: "Test Mac", device: "Test Mac",
      cpuCount: 10, performanceCPUCount: 8, availableDiskBytes: 500 * LocalHardwareProfile.gib,
      metalRecommendedWorkingSet: memory * LocalHardwareProfile.gib,
      metalMaximumBufferLength: 64 * LocalHardwareProfile.gib, lowPowerMode: false)
  }
}

private actor DiscoveryRequestRecorder {
  var urls: [URL] = []
  @discardableResult func record(_ url: URL) -> Int {
    urls.append(url)
    return urls.filter { $0 == url }.count
  }
}

private actor DiscoveryPageGate {
  private var continuation: CheckedContinuation<HuggingFaceModelPage, Never>?
  func wait(started: @Sendable () -> Void) async -> HuggingFaceModelPage {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started()
    }
  }
  func finish() {
    continuation?.resume(returning: HuggingFaceModelPage(models: [HuggingFaceModelListing(id: "org/old")]))
    continuation = nil
  }
}

private actor DiscoveryTestEngine: LocalModelEngine {
  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { nil }
  func installedModels() async -> [LocalModel] { [] }
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    throw LocalInferenceError.invalidModelFile
  }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func unload() async {}
}
