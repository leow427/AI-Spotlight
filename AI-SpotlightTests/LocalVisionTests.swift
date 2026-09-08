import AppKit
import Combine
import CryptoKit
import Darwin
import SwiftUI
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

  func testBundledVisionPackagesPinMatchingPairsAndOfficialRuntime() throws {
    XCTAssertEqual(LocalVisionModelDescriptor.bundled.count, 13)
    for model in LocalVisionModelDescriptor.bundled {
      try model.validate()
      XCTAssertEqual(model.model.url.deletingLastPathComponent(), model.projector.url.deletingLastPathComponent())
      XCTAssertGreaterThan(model.downloadByteCount, model.model.expectedByteCount + model.projector.expectedByteCount)
    }
    try LocalVisionRuntime.bundled.validate()
    XCTAssertTrue(LocalVisionRuntime.bundled.archive.url.path.contains("b10797"))
    let input = LocalVisionModelDescriptor.bundled[0]
    let mismatched = LocalVisionModelDescriptor(id: input.id, displayName: input.displayName, summary: input.summary,
      model: input.model, projector: LocalVisionModelDescriptor.bundled[1].projector,
      estimatedRuntimeMemory: 4 * LocalHardwareProfile.gib)
    XCTAssertThrowsError(try mismatched.validate())
  }

  func testLegacyPackageExplainsMigrationWithoutChangingItsFiles() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try fixture(in: directory)
    let legacy = LocalModel(id: "smolvlm-2b-q4:vision", displayName: "SmolVLM 2.2B", fileURL: source.fileURL,
      visionConfiguration: source.visionConfiguration)
    let restored = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(legacy))
    XCTAssertEqual(restored, legacy)
    let image = PreparedScreenImage(data: Data([0xff, 0xd8, 0xff, 0xd9]), mimeType: "image/jpeg", pixelWidth: 10, pixelHeight: 10)
    XCTAssertNoThrow(try LlamaServerVisionEngine.prepare(messages: [ChatMessage(role: .user, content: "Define serendipity.")], image: nil, model: restored))
    XCTAssertThrowsError(try LlamaServerVisionEngine.prepare(messages: [ChatMessage(role: .user, content: "Describe the shapes.")], image: image, model: restored)) { error in
      XCTAssertTrue(error.localizedDescription.contains("Settings → Local Models"))
      XCTAssertTrue(error.localizedDescription.contains("draft has been kept"))
    }
    var repaired = restored
    repaired.visionConfiguration?.packageRevision = "1bc3c9f74ceafd4c8d4411cc9cf188bba3798f91"
    XCTAssertNoThrow(try LlamaServerVisionEngine.prepare(messages: [ChatMessage(role: .user, content: "Describe the shapes.")], image: image, model: repaired))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.fileURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.visionConfiguration!.projectorURL.path))
    XCTAssertFalse(LocalModelManifest.bundled.models.contains { $0.id.contains("smol") })
  }

  func testPackageReplacementPreservesSelectedVisionAndRollsBackOnFailure() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = directory.appending(path: "library")
    let store = LocalModelInstallationStore(modelsDirectory: library)
    let source = try fixture(in: directory)
    let descriptor = LocalVisionModelDescriptor.bundled[1]
    let legacy = LocalModel(id: descriptor.id, displayName: "SmolVLM 2.2B", fileURL: source.fileURL,
      visionConfiguration: source.visionConfiguration)
    let original = try store.install(legacy)
    try store.selectModel(id: original.id)
    var updated = LocalModel(id: descriptor.id, displayName: descriptor.displayName, fileURL: source.fileURL,
      visionConfiguration: source.visionConfiguration)
    updated.visionConfiguration?.packageRevision = descriptor.packageRevision
    var operations = LocalModelInstallationStore.FileOperations()
    operations.writeMetadata = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
    XCTAssertThrowsError(try LocalModelInstallationStore(modelsDirectory: library, fileOperations: operations).install(updated))
    XCTAssertEqual(store.installedModel(), original)
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.fileURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.visionConfiguration!.projectorURL.path))
    let replacement = try store.install(updated)
    let restored = LocalModelInstallationStore(modelsDirectory: library)
    XCTAssertEqual(restored.installedModel(), replacement)
    XCTAssertEqual(restored.installedModels().count, 1)
    XCTAssertEqual(replacement.id, original.id, "Keep both the primary selection and persisted Screen model ID valid")
    XCTAssertEqual(replacement.visionConfiguration?.packageRevision, descriptor.packageRevision)
    XCTAssertFalse(descriptor.requiresUpdate(replacement))
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.fileURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.visionConfiguration!.projectorURL.path))
  }

  func testReadinessProbeDistinguishesBoundAndListeningLoopbackPort() throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        XCTAssertEqual(Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)), 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(getsockname(descriptor, $0, &size), 0)
      }
    }
    let port = UInt16(bigEndian: address.sin_port)
    let start = ContinuousClock.now
    XCTAssertFalse(LocalOnlyNetworking.isListening(on: port))
    XCTAssertLessThan(start.duration(to: .now), .seconds(1), "A non-listening port must not stall startup on TCP retries")
    XCTAssertEqual(listen(descriptor, 1), 0)
    XCTAssertTrue(LocalOnlyNetworking.isListening(on: port))
  }

  func testGuidedDownloadInstallsAllPartsAndPreservesTextModel() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try downloadFixture(in: directory)
    let store = LocalModelInstallationStore(modelsDirectory: directory.appending(path: "library"))
    let original = try store.install(LocalModel(id: "text", displayName: "Text", fileURL: package.source.fileURL))
    let session = downloadSession()
    defer { session.invalidateAndCancel() }
    let progress = VisionProgressProbe()
    let catalog = LocalModelCatalog(installationStore: store, session: session, availableDisk: { _ in 100 * LocalHardwareProfile.gib })
    let installed = try await catalog.downloadVision(package.descriptor, runtime: package.runtime) { await progress.record($0) }
    XCTAssertEqual(store.installedModel(), original)
    XCTAssertEqual(store.installedModels().count, 2)
    XCTAssertTrue(installed.supportsVision)
    let config = try XCTUnwrap(installed.visionConfiguration)
    XCTAssertEqual(config.packageRevision, package.descriptor.packageRevision)
    let managed = try XCTUnwrap(config.managedRuntimeDirectory)
    XCTAssertTrue(config.serverExecutableURL.path.hasPrefix(managed.path + "/"))
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: config.serverExecutableURL.path))
    XCTAssertEqual(try Data(contentsOf: installed.fileURL), try Data(contentsOf: package.source.fileURL))
    XCTAssertEqual(try Data(contentsOf: config.projectorURL), try Data(contentsOf: package.source.visionConfiguration!.projectorURL))
    let updates = await progress.values
    XCTAssertEqual(updates.last?.fractionCompleted, 1)
    XCTAssertEqual(updates.map(\.receivedByteCount), updates.map(\.receivedByteCount).sorted())
    let expected = package.descriptor.model.expectedByteCount + package.descriptor.projector.expectedByteCount + package.runtime.archive.expectedByteCount
    XCTAssertTrue(updates.allSatisfy { $0.expectedByteCount == expected })
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.modelsDirectoryURL.path).contains { $0.hasPrefix(".") })
    // Replacing the package retires only the old app-owned runtime.
    let replacement = try await catalog.downloadVision(package.descriptor, runtime: package.runtime) { _ in }
    XCTAssertNotEqual(replacement.visionConfiguration?.managedRuntimeDirectory, managed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
    XCTAssertEqual(store.installedModel(), original)
  }

  func testNormalInstallationSelectsCompletePackageAndUpgradeFailureKeepsItUsable() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try downloadFixture(in: directory)
    let store = LocalModelInstallationStore(modelsDirectory: directory.appending(path: "library"))
    let text = try store.install(LocalModel(id: "old-text", displayName: "Old text", fileURL: package.source.fileURL))
    let base = LocalModelManifest.bundled.models[0]
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
    json["downloadURL"] = package.descriptor.model.url.absoluteString
    json["expectedByteCount"] = package.descriptor.model.expectedByteCount
    json["checksumSHA256"] = package.descriptor.model.checksumSHA256
    json["projector"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(package.descriptor.projector))
    let descriptor = try JSONDecoder().decode(LocalModelDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
    let session = downloadSession()
    defer { session.invalidateAndCancel() }
    let progress = VisionProgressProbe()
    let hardware = LocalHardwareProfile(physicalMemory: 64 * LocalHardwareProfile.gib, isAppleSilicon: true,
      hasMetal: true, hasUnifiedMemory: true, chip: "Fixture", device: "Fixture", cpuCount: 12, performanceCPUCount: 8,
      availableDiskBytes: 200 * LocalHardwareProfile.gib, metalRecommendedWorkingSet: nil,
      metalMaximumBufferLength: 8 * LocalHardwareProfile.gib, lowPowerMode: false)
    let catalog = LocalModelCatalog(installationStore: store, session: session, detectHardware: { _ in hardware })
    let installed = try await catalog.download(descriptor, runtime: package.runtime) { await progress.record($0) }
    XCTAssertEqual(store.installedModel(), installed)
    XCTAssertTrue(installed.supportsVision)
    XCTAssertEqual(installed.catalogDescriptor, descriptor)
    XCTAssertFalse(descriptor.requiresUpdate(installed))
    XCTAssertEqual(installed.visionConfiguration?.contextWindow, 8192)
    XCTAssertTrue(FileManager.default.fileExists(atPath: text.fileURL.path), "Migration retains legacy weights")
    let values = await progress.values
    XCTAssertEqual(values.last?.receivedByteCount, package.descriptor.model.expectedByteCount
      + package.descriptor.projector.expectedByteCount + package.runtime.archive.expectedByteCount)
    var operations = LocalModelInstallationStore.FileOperations()
    operations.writeMetadata = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
    let failed = LocalModelCatalog(installationStore: LocalModelInstallationStore(modelsDirectory: store.modelsDirectoryURL,
      fileOperations: operations), session: session, detectHardware: { _ in hardware })
    let before = try FileManager.default.contentsOfDirectory(atPath: store.modelsDirectoryURL.path).sorted()
    do { _ = try await failed.download(descriptor, runtime: package.runtime) { _ in }; XCTFail("Expected rollback") }
    catch { }
    XCTAssertEqual(store.installedModel(), installed)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.modelsDirectoryURL.path).sorted(), before)
    let upgraded = try await catalog.download(descriptor, runtime: package.runtime) { _ in }
    XCTAssertEqual(store.installedModel(), upgraded)
    XCTAssertNotEqual(upgraded.fileURL, installed.fileURL)
    XCTAssertFalse(descriptor.requiresUpdate(upgraded))
    XCTAssertTrue(FileManager.default.fileExists(atPath: text.fileURL.path))
  }

  func testArtifactReportsProgressBeforeCompletionAndCanCancelMidTransfer() async throws {
    for cancel in [false, true] {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let bytes = Data(repeating: 42, count: 512 * 1024)
      let url = URL(string: "https://example.test/\(UUID()).gguf")!
      let gate = VisionDownloadGate()
      StreamingArtifactProtocol.set(url, data: bytes, gate: gate)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [StreamingArtifactProtocol.self]
      let session = URLSession(configuration: configuration)
      defer { session.invalidateAndCancel() }
      let artifact = VerifiedModelArtifact(url: url, expectedByteCount: Int64(bytes.count),
        checksumSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
      let received = expectation(description: "Progress before the server sends its second half")
      received.assertForOverFulfill = false
      let finished = expectation(description: "Download finishes")
      let output = directory.appending(path: "model.gguf")
      let task = Task {
        defer { finished.fulfill() }
        try await artifact.download(to: output, session: session) { update in
          if update.receivedByteCount > 0 && update.receivedByteCount < update.expectedByteCount { received.fulfill() }
        }
      }
      await fulfillment(of: [received], timeout: 3)
      if cancel {
        task.cancel()
        await fulfillment(of: [finished], timeout: 3)
      }
      await gate.release()
      if !cancel { await fulfillment(of: [finished], timeout: 3) }
      do {
        try await task.value
        XCTAssertFalse(cancel, "A cancelled transfer must not complete successfully")
        XCTAssertEqual(try Data(contentsOf: output), bytes)
      } catch {
        XCTAssertTrue(cancel, error.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
      }
    }
  }

  func testOversizedArtifactStopsBeforeTheServerFinishesSending() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = URL(string: "https://example.test/\(UUID()).gguf")!
    let gate = VisionDownloadGate()
    StreamingArtifactProtocol.set(url, data: Data(repeating: 42, count: 512 * 1024), gate: gate)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingArtifactProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let artifact = VerifiedModelArtifact(url: url, expectedByteCount: 65_536, checksumSHA256: String(repeating: "a", count: 64))
    let finished = expectation(description: "Size limit terminates the transfer while the server is paused")
    let output = directory.appending(path: "model.gguf")
    let task = Task {
      defer { finished.fulfill() }
      try await artifact.download(to: output, session: session) { _ in }
    }
    await fulfillment(of: [finished], timeout: 3)
    await gate.release()
    do { try await task.value; XCTFail("Expected the in-flight byte limit") }
    catch {
      guard case .unexpectedDownloadSize(let expected, let actual) = error as? LocalModelCatalogError else {
        return XCTFail("Wrong download error: \(error)")
      }
      XCTAssertEqual(expected, 65_536)
      XCTAssertGreaterThan(actual, expected)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  func testEachDownloadFailureRollsBackAndKeepsExistingSelection() async throws {
    for scenario in ["model checksum", "projector checksum", "runtime checksum", "truncated", "http", "runtime launch", "metadata", "disk"] {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let package = try downloadFixture(in: directory, runnable: scenario != "runtime launch")
      let store = LocalModelInstallationStore(modelsDirectory: directory.appending(path: "library"))
      let original = try store.install(LocalModel(id: "text", displayName: "Text", fileURL: package.source.fileURL))
      let before = try FileManager.default.contentsOfDirectory(atPath: store.modelsDirectoryURL.path).sorted()
      if scenario.contains("checksum") || scenario == "truncated" || scenario == "http" {
        let artifact = scenario.hasPrefix("model") ? package.descriptor.model
          : scenario.hasPrefix("runtime") ? package.runtime.archive : package.descriptor.projector
        let data = VisionDownloadProtocol.data(for: artifact.url)!
        let body = scenario == "truncated" ? Data(data.dropLast()) : Data(repeating: 0, count: data.count)
        VisionDownloadProtocol.set(artifact.url, data: body, status: scenario == "http" ? 503 : 200)
      }
      var operations = LocalModelInstallationStore.FileOperations()
      if scenario == "metadata" { operations.writeMetadata = { _, _ in throw CocoaError(.fileWriteOutOfSpace) } }
      let session = downloadSession()
      defer { session.invalidateAndCancel() }
      let catalog = LocalModelCatalog(installationStore: LocalModelInstallationStore(modelsDirectory: store.modelsDirectoryURL, fileOperations: operations),
        session: session, availableDisk: { _ in scenario == "disk" ? 0 : 100 * LocalHardwareProfile.gib })
      do {
        _ = try await catalog.downloadVision(package.descriptor, runtime: package.runtime) { _ in }
        XCTFail("Expected \(scenario) failure")
      } catch { }
      XCTAssertEqual(store.installedModel(), original, scenario)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.modelsDirectoryURL.path).sorted(), before, scenario)
    }
  }

  func testCancellingGuidedDownloadRemovesPartialPackage() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try downloadFixture(in: directory)
    let store = LocalModelInstallationStore(modelsDirectory: directory.appending(path: "library"))
    let session = downloadSession()
    defer { session.invalidateAndCancel() }
    let gate = VisionDownloadGate()
    let received = expectation(description: "First artifact downloaded")
    let catalog = LocalModelCatalog(installationStore: store, session: session, availableDisk: { _ in 100 * LocalHardwareProfile.gib })
    let task = Task {
      try await catalog.downloadVision(package.descriptor, runtime: package.runtime) { update in
        if update.receivedByteCount == package.descriptor.model.expectedByteCount {
          await gate.wait { received.fulfill() }
        }
      }
    }
    await fulfillment(of: [received], timeout: 3)
    task.cancel()
    await gate.release()
    do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
    XCTAssertTrue(store.installedModels().isEmpty)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.modelsDirectoryURL.path), [])
  }

  @MainActor
  func testObsoleteVisionPreferenceIsRetiredWithoutSelectingOrDeletingModels() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "VisionChoice-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LocalModelInstallationStore(modelsDirectory: directory.appending(path: "library"))
    let source = try fixture(in: directory)
    let text = try store.install(LocalModel(id: "text", displayName: "Text", fileURL: source.fileURL))
    let vision = try store.install(source)
    defaults.set(vision.id, forKey: "screen.localVisionModelID")
    defaults.set(true, forKey: "screen.allowCloudScreenshots")
    defaults.set(true, forKey: "screen.hasExplainedCloudPermission")
    let settings = ScreenSettings(defaults: defaults)
    XCTAssertNil(defaults.object(forKey: "screen.localVisionModelID"))
    XCTAssertEqual(store.installedModel(), text)
    XCTAssertEqual(store.installedModels().count, 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: vision.fileURL.path))
    XCTAssertTrue(settings.allowCloudScreenshots)
    XCTAssertTrue(settings.hasExplainedCloudPermission)
  }

  @MainActor
  func testDownloadActionSerializesCancellationAndActivatesOnlyCompletedModel() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = VisionDownloadEngineFixture(model: try fixture(in: directory))
    let chat = LocalChatViewModel(engine: engine, sessionStore: ChatSessionStore(applicationSupportDirectory: directory))
    for cancelled in [true, false] {
      let started = expectation(description: "Download producer started")
      await engine.setStarted(started)
      let done = expectation(description: "Download lifecycle finished")
      let token = chat.$state.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in done.fulfill() }
      chat.downloadModel(LocalModelManifest.bundled.models[0])
      chat.downloadModel(LocalModelManifest.bundled.models[0])
      await fulfillment(of: [started], timeout: 3)
      XCTAssertTrue(chat.isBusy)
      if cancelled {
        chat.cancelInstallation()
        XCTAssertTrue(chat.isBusy, "Keep requests blocked until cancellation is acknowledged")
      }
      await engine.complete()
      await fulfillment(of: [done], timeout: 3)
      token.cancel()
      XCTAssertFalse(chat.isBusy)
      XCTAssertEqual(chat.installedModels.count, cancelled ? 0 : 1)
    }
    let calls = await engine.calls
    XCTAssertEqual(calls, 2)
  }

  @MainActor
  func testGuidedDownloadViewShowsChoicesWithoutFilePickers() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let chat = LocalChatViewModel(engine: LlamaCPPModelEngine(installationStore: LocalModelInstallationStore(modelsDirectory: directory)))
    // The ranked list excludes unsuitable models; use the same Mac profile
    // on CI and locally so these assertions verify layout, not host resources.
    let profile = LocalHardwareProfile(physicalMemory: 24 * LocalHardwareProfile.gib,
      isAppleSilicon: true, hasMetal: true, hasUnifiedMemory: true,
      chip: "Apple Silicon (24 GB fixture)", device: "Fixture Mac", cpuCount: 12, performanceCPUCount: 6,
      availableDiskBytes: 200 * LocalHardwareProfile.gib, metalRecommendedWorkingSet: nil,
      metalMaximumBufferLength: 8 * LocalHardwareProfile.gib, lowPowerMode: false)
    let advisor = LocalModelAdvisor(directory: directory, modelsDirectory: directory, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    let view = NSHostingView(rootView: Form { LocalModelManagerSection(advisor: advisor, chat: chat) }.formStyle(.grouped))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 950), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(x: 0, y: 0, width: 680, height: 950)
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    // CI can render at a lower backing scale than a Retina Mac, making exact
    // model names ambiguous to OCR. Keep assertions exact and render at 3x.
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int(view.bounds.width * 3), pixelsHigh: Int(view.bounds.height * 3),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    XCTAssertEqual(bitmap.pixelsWide, Int(view.bounds.width * 3))
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Guided image-model downloads"
    attachment.lifetime = .keepAlways
    add(attachment)
    try png.write(to: URL(fileURLWithPath: "/tmp/ai-spotlight-vision-download-preview.png"))
    let text = try await ScreenOCRService().recognize(try XCTUnwrap(bitmap.cgImage)).text
    XCTAssertTrue(text.contains("Local Models"), text)
    XCTAssertFalse(text.contains("Image understanding"), text)
    XCTAssertTrue(text.contains("Qwen3"), text)
    XCTAssertTrue(text.contains("Google Gemma 4 E4B"), text)
    XCTAssertTrue(text.contains("OpenBMB"), text)
    XCTAssertTrue(text.contains("Mistral"), text)
    XCTAssertTrue(text.contains("everyday writing and screenshot understanding"), text)
    XCTAssertTrue(text.contains("Best choices for this Mac"), text)
    XCTAssertFalse(text.contains("SmolVLM"), text)
    XCTAssertTrue(text.contains("Install"), text)
    XCTAssertFalse(text.contains("Choose a file"), text)
  }

  @MainActor
  func testLegacyPackageViewOffersAnUpdateInsteadOfReady() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try fixture(in: directory)
    let descriptor = LocalVisionModelDescriptor.bundled[1]
    let store = LocalModelInstallationStore(modelsDirectory: directory.appending(path: "library"))
    _ = try store.install(LocalModel(id: descriptor.id, displayName: "SmolVLM 2.2B", fileURL: source.fileURL,
      visionConfiguration: source.visionConfiguration))
    let chat = LocalChatViewModel(engine: LlamaCPPModelEngine(installationStore: store),
      sessionStore: ChatSessionStore(applicationSupportDirectory: directory))
    await chat.refreshInstalledModel()
    // The ranked list excludes unsuitable models; use the same Mac profile
    // on CI and locally so these assertions verify layout, not host resources.
    let profile = LocalHardwareProfile(physicalMemory: 24 * LocalHardwareProfile.gib,
      isAppleSilicon: true, hasMetal: true, hasUnifiedMemory: true,
      chip: "Apple Silicon (24 GB fixture)", device: "Fixture Mac", cpuCount: 12, performanceCPUCount: 6,
      availableDiskBytes: 200 * LocalHardwareProfile.gib, metalRecommendedWorkingSet: nil,
      metalMaximumBufferLength: 8 * LocalHardwareProfile.gib, lowPowerMode: false)
    let advisor = LocalModelAdvisor(directory: directory, modelsDirectory: directory, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    let view = NSHostingView(rootView: Form { LocalModelManagerSection(advisor: advisor, chat: chat) }.formStyle(.grouped))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 1200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(x: 0, y: 0, width: 680, height: 1200)
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    // CI can render at a lower backing scale than a Retina Mac, making exact
    // model names ambiguous to OCR. Keep assertions exact and render at 3x.
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int(view.bounds.width * 3), pixelsHigh: Int(view.bounds.height * 3),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    XCTAssertEqual(bitmap.pixelsWide, Int(view.bounds.width * 3))
    let text = try await ScreenOCRService().recognize(try XCTUnwrap(bitmap.cgImage)).text
    // A separate Update line verifies the button, not just the explanatory
    // caption. CI OCR can confuse the similar l/I glyphs in this brand name;
    // normalize only that spelling while retaining the full model/version check.
    XCTAssertTrue(text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "Update" }, text)
    XCTAssertTrue(text.contains("Qwen3"), text)
    XCTAssertFalse(text.contains("Ready for Screen"), text)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Update the incompatible 2.2B package"
    attachment.lifetime = .keepAlways
    add(attachment)
    try png.write(to: URL(fileURLWithPath: "/tmp/ai-spotlight-vision-update-preview.png"))
  }

  func testServerPreparationUsesRealTokenCountsAndReusesPreparedContextForGeneration() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var model = try controlledRuntimeModel(in: directory)
    model.visionConfiguration?.contextWindow = 16_384
    let runtime = LlamaServerVisionEngine()
    let messages = [ChatMessage(role: .user, content: String(repeating: "Unicode evidence 🌍 ", count: 900))]
    let prepared = try await runtime.prepare(messages: messages, image: nil, model: model)
    XCTAssertEqual(prepared.budget.contextWindow, 16_384)
    XCTAssertEqual(prepared.messages, messages, "UTF-8 size must not reject text that the tokenizer says fits")
    XCTAssertLessThan(prepared.inputTokenCount, messages[0].content.utf8.count / 2)
    let before = await runtime.runtimeProcessIdentifier()
    let output = try await ScreenSearchContext.collect(runtime.stream(messages: prepared.messages, image: nil, model: model), maximumBytes: 100)
    XCTAssertEqual(output, "fixture answer")
    let after = await runtime.runtimeProcessIdentifier()
    XCTAssertEqual(before, after)
    let log = try String(contentsOf: directory.appending(path: "requests.jsonl"), encoding: .utf8)
      .split(separator: "\n").map { try JSONDecoder().decode(CodexValue.self, from: Data($0.utf8)) }
    let template = try XCTUnwrap(log.first { $0["path"].string == "/apply-template" })
    let completion = try XCTUnwrap(log.first { $0["path"].string == "/v1/chat/completions" })
    XCTAssertEqual(template["body"]["messages"], completion["body"]["messages"])
    XCTAssertEqual(template["body"]["chat_template_kwargs"], completion["body"]["chat_template_kwargs"])
    XCTAssertEqual(template["body"]["messages"].array?.first?["content"].string, ChatResponseStyle.instructions)
    let tokenize = try XCTUnwrap(log.first { $0["path"].string == "/tokenize" })
    XCTAssertEqual(tokenize["body"]["add_special"], .bool(true))
    XCTAssertEqual(tokenize["body"]["parse_special"], .bool(true))
    let image = PreparedScreenImage(data: Data([0xff, 0xd8, 0xff, 0xd9]), mimeType: "image/jpeg", pixelWidth: 10, pixelHeight: 10)
    let imagePrepared = try await runtime.prepare(messages: messages, image: image, model: model)
    XCTAssertEqual(imagePrepared.inputTokenCount, prepared.inputTokenCount + 4_096)
    await runtime.unload()
  }

  func testUnavailableOrMalformedTokenizerFallsBackWithoutRepeatedEndpointRequests() async throws {
    for mode in ["unavailable", "malformed"] {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = try controlledRuntimeModel(in: directory, tokenizer: mode)
      let runtime = LlamaServerVisionEngine()
      let messages = [ChatMessage(role: .user, content: "Small question")]
      let fallback = try LlamaServerVisionEngine.prepare(messages: messages, image: nil, model: model)
      for _ in 0..<2 {
        let prepared = try await runtime.prepare(messages: messages, image: nil, model: model)
        XCTAssertEqual(prepared, fallback)
      }
      let log = try String(contentsOf: directory.appending(path: "requests.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(CodexValue.self, from: Data($0.utf8)) }
      XCTAssertEqual(log.filter { $0["path"].string == "/apply-template" }.count, 1)
      do {
        _ = try await runtime.prepare(messages: [ChatMessage(role: .user, content: String(repeating: "x", count: 10_000))], image: nil, model: model)
        XCTFail("Fallback must still enforce the full output reserve")
      } catch { XCTAssertTrue(error is ChatContextError) }
      await runtime.unload()
    }
  }

  func testCancellingTokenizerPreparationClosesRuntimeInsteadOfFallingBack() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try controlledRuntimeModel(in: directory)
    let runtime = LlamaServerVisionEngine()
    let task = Task { try await runtime.prepare(messages: [ChatMessage(role: .user, content: "hold-tokenizer")], image: nil, model: model) }
    try await waitForRuntimeCondition { FileManager.default.fileExists(atPath: directory.appending(path: "tokenizer-started").path) }
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    try await waitForRuntimeCondition { await runtime.runtimeProcessIdentifier() == nil }
  }

  func testResidentRuntimeReusesModelForTextImagesAndPlanningThenSwitchesAndUnloads() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try controlledRuntimeModel(in: directory)
    let runtime = LlamaServerVisionEngine()
    let image = PreparedScreenImage(data: Data([0xff, 0xd8, 0xff, 0xd9]), mimeType: "image/jpeg", pixelWidth: 10, pixelHeight: 10)
    var firstPID: Int32?
    for inputImage in [nil, image, nil, image] {
      let output = try await ScreenSearchContext.collect(runtime.stream(
        messages: [ChatMessage(role: .user, content: "A controlled request")], image: inputImage, model: model), maximumBytes: 100)
      XCTAssertEqual(output, "fixture answer")
      let pid = await runtime.runtimeProcessIdentifier()
      XCTAssertNotNil(pid)
      if let firstPID { XCTAssertEqual(pid, firstPID, "Text/image stages must not reload the same model") }
      else { firstPID = pid }
    }
    let replacement = LocalModel(id: "replacement", displayName: "Replacement", fileURL: model.fileURL,
      visionConfiguration: model.visionConfiguration)
    _ = try await ScreenSearchContext.collect(runtime.stream(
      messages: [ChatMessage(role: .user, content: "Switch")], image: nil, model: replacement), maximumBytes: 100)
    let nextPID = await runtime.runtimeProcessIdentifier()
    XCTAssertNotEqual(nextPID, firstPID)
    await runtime.unload()
    let unloaded = await runtime.runtimeProcessIdentifier()
    XCTAssertNil(unloaded)
    for pid in [firstPID, nextPID].compactMap({ $0 }) {
      try await waitForRuntimeCondition { Darwin.kill(pid, 0) != 0 }
    }
  }

  func testResidentRuntimeCancellationAndIdleCleanupReleaseTheChild() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try controlledRuntimeModel(in: directory)
    let runtime = LlamaServerVisionEngine(idleDelay: .milliseconds(30))
    let task = Task {
      try await ScreenSearchContext.collect(runtime.stream(messages: [ChatMessage(role: .user, content: "hold")],
        image: nil, model: model), maximumBytes: 100)
    }
    let marker = directory.appending(path: "request-started")
    try await waitForRuntimeCondition { FileManager.default.fileExists(atPath: marker.path) }
    let pid = await runtime.runtimeProcessIdentifier()
    XCTAssertNotNil(pid)
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
    try await waitForRuntimeCondition { await runtime.runtimeProcessIdentifier() == nil }
    if let pid { try await waitForRuntimeCondition { Darwin.kill(pid, 0) != 0 } }
    _ = try await ScreenSearchContext.collect(runtime.stream(messages: [ChatMessage(role: .user, content: "Retry")],
      image: nil, model: model), maximumBytes: 100)
    try await waitForRuntimeCondition { await runtime.runtimeProcessIdentifier() == nil }
  }

  func testApplicationTerminationDoesNotLeaveTheModelProcessRunning() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try controlledRuntimeModel(in: directory)
    let runtime = LlamaServerVisionEngine()
    _ = try await ScreenSearchContext.collect(runtime.stream(messages: [ChatMessage(role: .user, content: "Hello")],
      image: nil, model: model), maximumBytes: 100)
    let identifier = await runtime.runtimeProcessIdentifier()
    let pid = try XCTUnwrap(identifier)
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    try await waitForRuntimeCondition { Darwin.kill(pid, 0) != 0 }
    await runtime.unload()
  }

  private func waitForRuntimeCondition(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { XCTFail("Runtime condition did not complete"); return }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func controlledRuntimeModel(in directory: URL, tokenizer: String = "available") throws -> LocalModel {
    let source = try fixture(in: directory)
    let server = directory.appending(path: "controlled-server")
    try Data(tokenizer.utf8).write(to: directory.appending(path: "tokenizer-mode"))
    let script = #"""
    #!/usr/bin/python3
    import http.server, json, sys, pathlib, threading
    port = int(sys.argv[sys.argv.index('--port') + 1])
    alias = sys.argv[sys.argv.index('--alias') + 1]
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            self.send_response(200); self.end_headers()
            self.wfile.write(json.dumps({'data': [{'id': alias}]} if self.path == '/v1/models' else {'status': 'ok'}).encode())
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            root = pathlib.Path(__file__).parent
            with (root / 'requests.jsonl').open('a') as log:
                log.write(json.dumps({'path': self.path, 'body': body}) + '\n')
            if self.path in ['/apply-template', '/tokenize']:
                mode = (root / 'tokenizer-mode').read_text()
                if mode == 'unavailable':
                    self.send_response(404); self.end_headers(); return
                if self.path == '/tokenize' and 'hold-tokenizer' in body['content']:
                    (root / 'tokenizer-started').write_text('ready')
                    threading.Event().wait()
                result = {'prompt': json.dumps(body['messages'], ensure_ascii=False)} if self.path == '/apply-template' else {'tokens': list(range((len(body['content']) + 3) // 4))}
                if mode == 'malformed' and self.path == '/tokenize': result = {'tokens': 'invalid'}
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
                self.wfile.write(json.dumps(result).encode()); return
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
            if body['messages'][-1]['content'] == 'hold':
                pathlib.Path(__file__).with_name('request-started').write_text('ready')
                self.wfile.write(b': waiting\n\n'); self.wfile.flush(); threading.Event().wait()
            else:
                self.wfile.write(b'data: {"choices":[{"delta":{"content":"fixture answer"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
                self.wfile.flush()
    http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()
    """#
    try Data(script.utf8).write(to: server)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
    return LocalModel(id: source.id, displayName: source.displayName, fileURL: source.fileURL,
      visionConfiguration: LocalVisionConfiguration(projectorURL: source.visionConfiguration!.projectorURL, serverExecutableURL: server))
  }

  private func downloadSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VisionDownloadProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func downloadFixture(in directory: URL, runnable: Bool = true) throws
    -> (descriptor: LocalVisionModelDescriptor, runtime: LocalVisionRuntime, source: LocalModel) {
    let source = try fixture(in: directory)
    let input = LocalVisionModelDescriptor.bundled[0]
    func artifact(_ url: URL, _ bytes: Data) -> VerifiedModelArtifact {
      // Unique URLs isolate simultaneous test processes while retaining pinned paths.
      let url = URL(string: url.absoluteString + "?fixture=" + directory.lastPathComponent)!
      VisionDownloadProtocol.set(url, data: bytes)
      return VerifiedModelArtifact(url: url, expectedByteCount: Int64(bytes.count),
        checksumSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    let descriptor = LocalVisionModelDescriptor(id: input.id, displayName: input.displayName, summary: input.summary,
      model: artifact(input.model.url, try Data(contentsOf: source.fileURL)),
      projector: artifact(input.projector.url, try Data(contentsOf: source.visionConfiguration!.projectorURL)),
      estimatedRuntimeMemory: 1024)
    let runtimeRoot = directory.appending(path: LocalVisionRuntime.directoryName)
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
    let server = runtimeRoot.appending(path: "llama-server")
    try Data((runnable ? "#!/bin/sh\nprintf '%s' '--mmproj --offline'\n" : "#!/bin/sh\nexit 1\n").utf8).write(to: server)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
    let archive = directory.appending(path: "runtime.tar.gz")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-czf", archive.path, "-C", directory.path, LocalVisionRuntime.directoryName]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let bytes = try Data(contentsOf: archive)
    let runtimeURL = LocalVisionRuntime.bundled.archive.url
    VisionDownloadProtocol.set(runtimeURL, data: bytes)
    let runtime = LocalVisionRuntime(archive: VerifiedModelArtifact(url: runtimeURL, expectedByteCount: Int64(bytes.count),
      checksumSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
    return (descriptor, runtime, source)
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

private actor VisionProgressProbe {
  var values: [ModelDownloadProgress] = []
  func record(_ progress: ModelDownloadProgress) { values.append(progress) }
}

private actor VisionDownloadGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  func wait(onReady: @Sendable () -> Void) async {
    guard !released else { return }
    await withCheckedContinuation { continuation = $0; onReady() }
  }
  func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class VisionDownloadProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responses: [URL: (Data, Int)] = [:]
  static func set(_ url: URL, data: Data, status: Int = 200) { lock.withLock { responses[url] = (data, status) } }
  static func data(for url: URL) -> Data? { lock.withLock { responses[url]?.0 } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let (data, status) = Self.lock.withLock({ Self.responses[url] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() { }
}

private actor VisionDownloadEngineFixture: LocalModelEngine {
  let model: LocalModel
  var calls = 0
  private var started: XCTestExpectation?
  private var continuation: CheckedContinuation<Void, Never>?
  private var installed: [LocalModel] = []
  init(model: LocalModel) { self.model = model }
  func setStarted(_ expectation: XCTestExpectation) { started = expectation }
  func complete() { continuation?.resume(); continuation = nil }
  func download(_ descriptor: LocalModelDescriptor,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    calls += 1
    await progress(ModelDownloadProgress(receivedByteCount: 1, expectedByteCount: 2))
    await withCheckedContinuation { continuation = $0; started?.fulfill() }
    if Task.isCancelled { throw URLError(.cancelled) }
    installed = [model]
    return model
  }
  func install(_ model: LocalModel) async throws { }
  func installedModel() async -> LocalModel? { nil }
  func installedModels() async -> [LocalModel] { installed }
  func selectModel(id: String) async throws { }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
  func unload() async { }
}

/// A paused response proves that progress, cancellation, and byte limits work
/// before download completion, without timing sleeps or external networking.
private final class StreamingArtifactProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responses: [URL: (Data, VisionDownloadGate)] = [:]
  private let producerLock = NSLock()
  private var producer: Task<Void, Never>?
  static func set(_ url: URL, data: Data, gate: VisionDownloadGate) { lock.withLock { responses[url] = (data, gate) } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let (data, gate) = Self.lock.withLock({ Self.responses.removeValue(forKey: url) }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(data.prefix(data.count / 2)))
    producerLock.withLock {
      producer = Task { @Sendable [self, data, gate] in
        await gate.wait(onReady: {})
        guard !Task.isCancelled else { return }
        client?.urlProtocol(self, didLoad: Data(data.suffix(data.count - data.count / 2)))
        client?.urlProtocolDidFinishLoading(self)
      }
    }
  }
  override func stopLoading() { producerLock.withLock { producer?.cancel() } }
}
