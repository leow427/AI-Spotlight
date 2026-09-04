import XCTest
@testable import PrimaryAgent

final class LocalVisionTests: XCTestCase {
  func testVisionPairPersistsAndDoesNotReplaceTextSelection() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalModelInstallationStore(modelsDirectory: directory.appendingPathComponent("library"))
    let input = try fixture(in: directory)
    let text = try store.install(LocalModel(id: "text", displayName: "Text", fileURL: input.fileURL))
    let vision = try store.install(input)
    XCTAssertEqual(store.installedModel()?.id, text.id)
    let restored = try XCTUnwrap(store.installedModels().first(where: \.supportsVision))
    XCTAssertEqual(restored, vision)
    XCTAssertNotEqual(restored.visionConfiguration?.projectorURL, input.visionConfiguration?.projectorURL)
    XCTAssertEqual(try Data(contentsOf: restored.visionConfiguration!.projectorURL), try Data(contentsOf: input.visionConfiguration!.projectorURL))
    XCTAssertTrue(restored.screenModel.canUseVision)
  }

  func testProjectorFailureRollsBackBothFilesAndPreservesSelection() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = directory.appendingPathComponent("library")
    let store = LocalModelInstallationStore(modelsDirectory: library)
    let input = try fixture(in: directory)
    let original = try store.install(LocalModel(id: "text", displayName: "Text", fileURL: input.fileURL))
    let before = try FileManager.default.contentsOfDirectory(atPath: library.path).sorted()
    var operations = LocalModelInstallationStore.FileOperations()
    operations.copyItem = { source, destination in
      if source == input.visionConfiguration?.projectorURL { throw CocoaError(.fileWriteOutOfSpace) }
      try FileManager.default.copyItem(at: source, to: destination)
    }
    XCTAssertThrowsError(try LocalModelInstallationStore(modelsDirectory: library, fileOperations: operations).install(input))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).sorted(), before)
    XCTAssertEqual(store.installedModel(), original)
  }

  func testServerLaunchUsesModelAndProjectorOfflineOnLoopback() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try fixture(in: directory)
    let args = try LlamaServerVisionEngine.arguments(model: model, port: 55432, key: "fixture", alias: "test")
    XCTAssertEqual(Array(args.prefix(4)), ["-m", model.fileURL.path, "--mmproj", model.visionConfiguration!.projectorURL.path])
    XCTAssertTrue(args.contains("--offline"))
    XCTAssertEqual(args[args.firstIndex(of: "--host")! + 1], "127.0.0.1")
    XCTAssertEqual(args[args.firstIndex(of: "--port")! + 1], "55432")
  }

  func testInvalidOrMissingProjectorCannotBecomeAVisionProfile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try fixture(in: directory)
    try Data("not GGUF".utf8).write(to: model.visionConfiguration!.projectorURL)
    XCTAssertThrowsError(try LocalVisionModelValidation.validate(model))
    XCTAssertThrowsError(try LocalModelInstallationStore(modelsDirectory: directory.appendingPathComponent("library")).install(model))
  }

  func testLocalSessionDisablesProxyCacheAndCloudRedirects() async {
    let session = LocalOnlyNetworking.makeSession()
    defer { session.invalidateAndCancel() }
    XCTAssertEqual(session.configuration.connectionProxyDictionary?.count, 0)
    XCTAssertNil(session.configuration.urlCache)
    let delegate = LocalOnlyRedirectDelegate()
    let task = session.dataTask(with: URL(string: "http://127.0.0.1:1234")!)
    let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
    let request = URLRequest(url: URL(string: "https://example.com/upload")!)
    await withCheckedContinuation { continuation in
      delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { redirected in
        XCTAssertNil(redirected)
        continuation.resume()
      }
    }
  }

  private func fixture(in directory: URL) throws -> LocalModel {
    let model = directory.appendingPathComponent("model.gguf")
    let projector = directory.appendingPathComponent("mmproj.gguf")
    let bytes = Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0]) + Data(repeating: 0, count: 24)
    try bytes.write(to: model)
    try bytes.write(to: projector)
    return LocalModel(id: "visual", displayName: "Vision", fileURL: model,
      visionConfiguration: LocalVisionConfiguration(projectorURL: projector, serverExecutableURL: URL(fileURLWithPath: "/usr/bin/true")))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVisionTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
