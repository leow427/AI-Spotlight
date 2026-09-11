import AppKit
import Combine
import CryptoKit
import SwiftUI
import XCTest
@testable import Enigma

@MainActor
final class HuggingFaceModelDownloadsTests: XCTestCase {
  func testRepositoryRejectsTraversalAndCaseCollisionsAndPinsDownloadURLs() throws {
    let valid = repository([file("vision/image support.gguf")])
    try valid.validate()
    XCTAssertEqual(valid.url(for: valid.siblings[0]).absoluteString,
      "https://huggingface.co/org/vision-model/resolve/\(revision)/vision/image%20support.gguf")
    for path in ["/tmp/model.gguf", "../model.gguf", "vision/../../model.gguf", "a//b", ".git/config", "a\\b", "a\nb"] {
      XCTAssertThrowsError(try repository([file(path)]).validate(), path)
    }
    XCTAssertThrowsError(try repository([file("Model.gguf"), file("model.gguf")]).validate())
    XCTAssertThrowsError(try HuggingFaceRepository(id: "org/model", sha: "main", siblings: [file("model.gguf")]).validate())
    XCTAssertThrowsError(try repository([HuggingFaceRepositoryFile(rfilename: "model.gguf", size: 4,
      blobId: revision, lfs: .init(sha256: String(repeating: "a", count: 64), size: 3))]).validate())
  }

  func testSuggestionsSelectOneQ4FamilyAllItsShardsAndImageProjector() {
    let repo = repository([
      file("model-Q4_K_M-00001-of-00002.gguf"), file("model-Q4_K_M-00002-of-00002.gguf"),
      file("model-Q8_0.gguf"), file("mmproj-bf16.gguf"), file("mmproj-f16.gguf"), file("mmproj-Q8_0.gguf"), file("README.md"),
    ])
    XCTAssertEqual(repo.suggestedFiles,
      ["model-Q4_K_M-00001-of-00002.gguf", "model-Q4_K_M-00002-of-00002.gguf", "mmproj-f16.gguf"])
    let audio = repository([file("model.safetensors"), file("config.json"), file("tokenizer.json")])
    XCTAssertEqual(audio.suggestedFiles, Set(audio.siblings.map(\.id)))
  }

  func testSelectedFilesDownloadAsOneSnapshotWithProgressAndNoExistingFileReplacement() async throws {
    let root = try temporaryDirectory()
    let keep = root.appending(path: "existing-model.txt")
    try Data("keep".utf8).write(to: keep)
    let repo = repository([file("weights/model.gguf"), file("vision/mmproj.gguf"), file("unused.gguf")])
    let recorder = DownloadProgressRecorder()
    let downloader = HuggingFaceFileDownloader { file, url, target, progress in
      await recorder.recordURL(url)
      try Data(repeating: 1, count: Int(file.size)).write(to: target)
      await progress(ModelDownloadProgress(receivedByteCount: file.size, expectedByteCount: file.size))
    }
    let result = try await downloader.download(repo, selected: ["weights/model.gguf", "vision/mmproj.gguf"], into: root) { name, progress in
      await recorder.recordProgress(progress)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.appending(path: "weights/model.gguf").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.appending(path: "vision/mmproj.gguf").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: result.appending(path: "unused.gguf").path))
    XCTAssertEqual(try Data(contentsOf: keep), Data("keep".utf8))
    let urls = await recorder.urls
    XCTAssertEqual(urls, repo.siblings.prefix(2).map { repo.url(for: $0) })
    let progress = await recorder.progress
    XCTAssertEqual(progress.map(\.receivedByteCount), [4, 8])
    XCTAssertEqual(progress.map(\.expectedByteCount), [8, 8])
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".enigma-download") })
  }

  func testFailureAndCancellationRemoveOnlyUncommittedDownloadFiles() async throws {
    for cancel in [false, true] {
      let root = try temporaryDirectory()
      try Data("keep".utf8).write(to: root.appending(path: "keep"))
      let repo = repository([file("first.gguf"), file("second.gguf")])
      let downloader = HuggingFaceFileDownloader { file, _, target, _ in
        if file.id == "second.gguf" {
          if cancel { throw CancellationError() }
          throw HuggingFaceDownloadError.checksumMismatch
        }
        try Data("test".utf8).write(to: target)
      }
      do {
        _ = try await downloader.download(repo, selected: Set(repo.siblings.map(\.id)), into: root) { _, _ in }
        XCTFail("Incomplete snapshots must not become available")
      } catch { }
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["keep"])
    }
  }

  func testGitFilesVerifyTheirPublishedChecksumAndRejectCorruptOrOversizedResponses() async throws {
    let root = try temporaryDirectory()
    let data = Data("test".utf8)
    let hash = Insecure.SHA1.hash(data: Data("blob 4\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
    let file = HuggingFaceRepositoryFile(rfilename: "config.json", size: 4, blobId: hash)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloadFixtureProtocol.self]
    let url = repository([file]).url(for: file)
    DownloadFixtureProtocol.body.set(data)
    let output = root.appending(path: "valid.json")
    try await HuggingFaceFileDownloader.transfer(file, from: url, to: output, configuration: configuration) { _ in }
    XCTAssertEqual(try Data(contentsOf: output), data)
    for (index, body) in [Data("nope".utf8), Data("too much".utf8), Data("x".utf8)].enumerated() {
      DownloadFixtureProtocol.body.set(body)
      do {
        try await HuggingFaceFileDownloader.transfer(file, from: url,
          to: root.appending(path: "bad-\(index)"), configuration: configuration) { _ in }
        XCTFail("Invalid file must be rejected")
      } catch { }
    }
  }

  func testMemoryWarningsPermitGemmaInstallationWithoutAutomaticBenchmarking() async throws {
    let root = try temporaryDirectory()
    let model = try XCTUnwrap(LocalModelManifest.bundled.models.first { $0.id == LocalModelDiscovery.featuredModelID })
    let gib = LocalHardwareProfile.gib
    let profile = LocalHardwareProfile(physicalMemory: 16 * gib, isAppleSilicon: true, hasMetal: true,
      hasUnifiedMemory: true, chip: "Test Mac", device: "Test Mac", cpuCount: 8, performanceCPUCount: 6,
      availableDiskBytes: 500 * gib, metalRecommendedWorkingSet: 16 * gib,
      metalMaximumBufferLength: 64 * gib, lowPowerMode: false)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    let assessment = try await advisor.confirmDownload(model, installedModels: [])
    XCTAssertTrue(assessment.permitsMemoryOverride)
    XCTAssertTrue(assessment.canInstall)
    XCTAssertFalse(assessment.isResponsive)
    var noDisk = profile
    noDisk.availableDiskBytes = 0
    XCTAssertFalse(LocalModelSelector.assess(model, hardware: noDisk).canInstall)
    let engine = DownloadInstallEngine()
    let chat = LocalChatViewModel(engine: engine, modelAdvisor: advisor,
      sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    let done = expectation(description: "Model installed without loading it")
    let observation = chat.$state.dropFirst().sink { if $0 == .idle { done.fulfill() } }
    chat.downloadModel(model)
    await fulfillment(of: [done], timeout: 3)
    observation.cancel()
    XCTAssertEqual(chat.installedModel?.id, model.id)
    XCTAssertTrue(chat.benchmarkNotice?.contains("Memory use may be high") == true)
    XCTAssertEqual(advisor.measurements.count, 0)
  }

  func testFileChooserRendersQuantizationsAndDownloadActionOffline() async throws {
    let repo = HuggingFaceRepository(id: "bartowski/google_gemma-4-26B-A4B-it-GGUF",
      sha: "10f3b41bcf8d3047f4e136e7197ffc2dd1654c9d", siblings: [
        HuggingFaceRepositoryFile(rfilename: "google_gemma-4-26B-A4B-it-Q4_K_M.gguf", size: 17_035_039_872,
          blobId: revision, lfs: .init(sha256: "a07f72221e8e3f77455ab0d7f7652d01a9f63c262b954aa6932a53275a0e895a", size: 17_035_039_872)),
        HuggingFaceRepositoryFile(rfilename: "mmproj-google_gemma-4-26B-A4B-it-f16.gguf", size: 1_193_058_528,
          blobId: revision, lfs: .init(sha256: "41cdabd1e8066e983ee6c288eb0117777376223ee0279cadcd67b2295e4d975f", size: 1_193_058_528)),
        file("README.md"),
      ])
    let loaded = expectation(description: "File list loaded")
    let view = NSHostingView(rootView: HuggingFaceDownloadSheet(model: HuggingFaceModelListing(id: repo.id),
      loadRepository: { _ in loaded.fulfill(); return repo }, downloads: HuggingFaceModelDownloads()))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.contentView = nil }
    view.layoutSubtreeIfNeeded()
    await fulfillment(of: [loaded], timeout: 3)
    for _ in 0..<5 { await Task.yield() }
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.fittingSize, NSSize(width: 620, height: 660))
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/Enigma-Model-Download.png"))
  }

  private let revision = String(repeating: "a", count: 40)
  private func file(_ path: String) -> HuggingFaceRepositoryFile {
    HuggingFaceRepositoryFile(rfilename: path, size: 4, blobId: revision)
  }
  private func repository(_ files: [HuggingFaceRepositoryFile]) -> HuggingFaceRepository {
    HuggingFaceRepository(id: "org/vision-model", sha: revision, siblings: files)
  }
  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "HFDownloadTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}

private actor DownloadProgressRecorder {
  var urls: [URL] = []
  var progress: [ModelDownloadProgress] = []
  func recordURL(_ url: URL) { urls.append(url) }
  func recordProgress(_ value: ModelDownloadProgress) { progress.append(value) }
}

private final class DownloadFixtureBody: @unchecked Sendable {
  private let lock = NSLock()
  private var body = Data()
  func set(_ value: Data) { lock.withLock { body = value } }
  func get() -> Data { lock.withLock { body } }
}

private final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
  static let body = DownloadFixtureBody()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let body = Self.body.get()
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
      httpVersion: nil, headerFields: ["Content-Length": String(body.count)])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private actor DownloadInstallEngine: LocalModelEngine {
  var model: LocalModel?
  func install(_ model: LocalModel) async throws { self.model = model }
  func installedModel() async -> LocalModel? { model }
  func installedModels() async -> [LocalModel] { model.map { [$0] } ?? [] }
  func selectModel(id: String) async throws {}
  func download(_ descriptor: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    let installed = LocalModel(id: descriptor.id, displayName: descriptor.displayName,
      fileURL: URL(fileURLWithPath: "/tmp/test-installed.gguf"), catalogDescriptor: descriptor)
    model = installed
    return installed
  }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
  func unload() async {}
}
