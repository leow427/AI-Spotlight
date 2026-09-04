import Foundation
import XCTest
@testable import PrimaryAgent

final class LocalModelInstallationStoreTests: XCTestCase {
  func testPunctuationCollisionsKeepIndependentBytesAndSelectionsAfterReload() throws {
    let fixture = try makeFixture()
    let first = try fixture.store.install(fixture.input(id: "model.v1", bytes: "first", name: "model.v1.gguf"))
    let second = try fixture.store.install(fixture.input(id: "model-v1", bytes: "second", name: "model-v1.gguf"))

    XCTAssertNotEqual(first.fileURL, second.fileURL)
    XCTAssertEqual(fixture.store.installedModels().count, 2)
    XCTAssertEqual(fixture.store.installedModel(), second)
    for (model, bytes) in [(first, "first"), (second, "second")] {
      try fixture.store.selectModel(id: model.id)
      let restored = try XCTUnwrap(fixture.store.installedModel())
      XCTAssertEqual(restored, model)
      XCTAssertEqual(try Data(contentsOf: restored.fileURL), Data(bytes.utf8))
    }
  }

  func testLongAndCaseCollidingIdentitiesHaveDistinctBoundedFilenames() throws {
    let fixture = try makeFixture()
    let prefix = String(repeating: "x", count: 80)
    let ids = [prefix + "-first", prefix + "-second", "MODEL", "model", "🦙", "--"]
    let installed = try ids.map { id in
      try fixture.store.install(fixture.input(id: id, bytes: id))
    }
    XCTAssertEqual(Set(installed.map { $0.fileURL.lastPathComponent.lowercased() }).count, ids.count)
    XCTAssertEqual(Set(fixture.store.installedModels().map(\.id)), Set(ids))
    for model in installed {
      XCTAssertLessThan(model.fileURL.lastPathComponent.utf8.count, 255)
      try fixture.store.selectModel(id: model.id)
      XCTAssertEqual(fixture.store.installedModel(), model)
      XCTAssertEqual(try Data(contentsOf: model.fileURL), Data(model.id.utf8))
    }
  }

  func testSameIdentityCommitsNewBytesBeforeRemovingItsPreviousFile() throws {
    let fixture = try makeFixture()
    let original = try fixture.store.install(fixture.input(id: "model.v1", bytes: "original"))
    let unrelated = try fixture.store.install(fixture.input(id: "unrelated", bytes: "unrelated"))
    let metadata = try Data(contentsOf: fixture.recordURL)
    let input = try fixture.input(id: original.id, bytes: "replacement")
    var operations = LocalModelInstallationStore.FileOperations()
    operations.writeMetadata = { data, url in
      XCTAssertEqual(try Data(contentsOf: original.fileURL), Data("original".utf8))
      XCTAssertEqual(try Data(contentsOf: url), metadata)
      let library = try JSONDecoder().decode(FixtureLibrary.self, from: data)
      let record = try XCTUnwrap(library.models.first { $0.id == original.id })
      let newURL = url.deletingLastPathComponent().appending(path: record.fileName)
      XCTAssertEqual(try Data(contentsOf: newURL), Data("replacement".utf8))
      try data.write(to: url, options: .atomic)
    }
    let replacement = try fixture.store(using: operations).install(input)

    XCTAssertEqual(replacement.id, original.id)
    XCTAssertNotEqual(replacement.fileURL, original.fileURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.fileURL.path))
    XCTAssertEqual(fixture.store.installedModel(), replacement)
    XCTAssertEqual(fixture.store.installedModels().count, 2)
    XCTAssertEqual(try Data(contentsOf: unrelated.fileURL), Data("unrelated".utf8))
  }

  func testReimportingTheInstalledFileItselfPreservesItsContents() throws {
    let fixture = try makeFixture()
    let first = try fixture.store.install(fixture.input(id: "model", bytes: "original"))
    let second = try fixture.store.install(first)
    XCTAssertNotEqual(first.fileURL, second.fileURL)
    XCTAssertEqual(try Data(contentsOf: second.fileURL), Data("original".utf8))
    XCTAssertEqual(fixture.store.installedModel(), second)
    XCTAssertEqual(fixture.store.installedModels(), [second])
  }

  func testLegacySingleRecordUpgradesWithoutMovingBytesOrChangingSelection() throws {
    let fixture = try makeFixture()
    let record = FixtureRecord(id: "model.v1", displayName: "Legacy", fileName: "model-v1.gguf")
    let originalURL = fixture.modelsURL.appending(path: record.fileName)
    try Data("legacy".utf8).write(to: originalURL)
    try JSONEncoder().encode(record).write(to: fixture.recordURL)
    let before = try fixture.snapshot()

    let selected = try XCTUnwrap(fixture.store.installedModel())
    XCTAssertEqual(selected.id, record.id)
    XCTAssertEqual(selected.fileURL, originalURL)
    XCTAssertEqual(fixture.store.installedModels(), [selected])
    XCTAssertEqual(try fixture.snapshot(), before, "Loading must not eagerly migrate files or metadata")

    try fixture.store.selectModel(id: selected.id)
    XCTAssertEqual(fixture.store.installedModel(), selected)
    let migrated = try JSONDecoder().decode(FixtureLibrary.self, from: Data(contentsOf: fixture.recordURL))
    XCTAssertEqual(migrated.selectedModelID, record.id)
    XCTAssertEqual(migrated.models.map(\.fileName), [record.fileName])

    _ = try fixture.store.install(fixture.input(id: "model-v1", bytes: "new"))
    try fixture.store.selectModel(id: selected.id)
    XCTAssertEqual(fixture.store.installedModel(), selected)
    XCTAssertEqual(try Data(contentsOf: selected.fileURL), Data("legacy".utf8))
  }

  func testExistingLibraryPreservesSelectionEntriesAndUntrackedFiles() throws {
    let fixture = try makeFixture()
    let records = [
      FixtureRecord(id: "first", displayName: "First", fileName: "old-first.gguf"),
      FixtureRecord(id: "model.v1", displayName: "Selected", fileName: "model-v1.gguf"),
      FixtureRecord(id: "last", displayName: "Last", fileName: "old-last.gguf"),
    ]
    for record in records {
      try Data(record.id.utf8).write(to: fixture.modelsURL.appending(path: record.fileName))
    }
    let untrackedURL = fixture.modelsURL.appending(path: "untracked.gguf")
    try Data("untracked bytes".utf8).write(to: untrackedURL)
    try fixture.writeLibrary(records, selected: "model.v1")
    let before = try fixture.snapshot()
    let selected = try XCTUnwrap(fixture.store.installedModel())
    XCTAssertEqual(selected.id, "model.v1")
    XCTAssertEqual(fixture.store.installedModels().count, 3)
    XCTAssertEqual(try fixture.snapshot(), before)

    try fixture.store.selectModel(id: selected.id)
    XCTAssertEqual(fixture.store.installedModel(), selected)
    _ = try fixture.store.install(fixture.input(id: "model-v1", bytes: "new"))
    XCTAssertEqual(fixture.store.installedModels().count, 4)
    for record in records {
      try fixture.store.selectModel(id: record.id)
      let model = try XCTUnwrap(fixture.store.installedModel())
      XCTAssertEqual(try Data(contentsOf: model.fileURL), Data(record.id.utf8))
    }
    XCTAssertEqual(try Data(contentsOf: untrackedURL), Data("untracked bytes".utf8))
  }

  func testReimportDoesNotRemoveFilesSharedByLegacyRecordsOrSymlinks() throws {
    for aliasName in ["model-v1.gguf", "MODEL-V1.gguf", "alias.gguf"] {
      let fixture = try makeFixture()
      let sharedURL = fixture.modelsURL.appending(path: "model-v1.gguf")
      try Data("surviving legacy bytes".utf8).write(to: sharedURL)
      if aliasName == "alias.gguf" {
        try FileManager.default.createSymbolicLink(
          at: fixture.modelsURL.appending(path: aliasName), withDestinationURL: sharedURL
        )
      } else if !FileManager.default.fileExists(atPath: fixture.modelsURL.appending(path: aliasName).path) {
        // Also run on case-sensitive test volumes, where these are separate files.
        try Data("surviving legacy bytes".utf8).write(to: fixture.modelsURL.appending(path: aliasName))
      }
      try fixture.writeLibrary([
        FixtureRecord(id: "model.v1", displayName: "First", fileName: "model-v1.gguf"),
        FixtureRecord(id: "model-v1", displayName: "Second", fileName: aliasName),
      ], selected: "model-v1")

      let replacement = try fixture.store.install(fixture.input(id: "model.v1", bytes: "new first"))
      XCTAssertEqual(try Data(contentsOf: replacement.fileURL), Data("new first".utf8))
      try fixture.store.selectModel(id: "model-v1")
      let remaining = try XCTUnwrap(fixture.store.installedModel())
      XCTAssertEqual(try Data(contentsOf: remaining.fileURL), Data("surviving legacy bytes".utf8))
      XCTAssertEqual(try Data(contentsOf: sharedURL), Data("surviving legacy bytes".utf8))
      XCTAssertEqual(fixture.store.installedModels().count, 2)
    }
  }

  func testCopyMoveAndMetadataFailuresLeaveExistingLibraryByteForByteIntact() throws {
    for failure in InstallationFailure.allCases {
      for replacing in [false, true] {
        let fixture = try makeFixture()
        _ = try fixture.store.install(fixture.input(id: "model.v1", bytes: "original"))
        let selected = try fixture.store.install(fixture.input(id: "selected", bytes: "selected bytes"))
        let before = try fixture.snapshot()
        let input = try fixture.input(id: replacing ? "model.v1" : "model-v1", bytes: "new")
        let failingStore = fixture.store(using: failure.operations)

        XCTAssertThrowsError(try failingStore.install(input))
        XCTAssertEqual(try fixture.snapshot(), before, "Failure: \(failure), replacing: \(replacing)")
        XCTAssertEqual(fixture.store.installedModel(), selected)
        XCTAssertEqual(fixture.store.installedModels().count, 2)
        try fixture.store.selectModel(id: "model.v1")
        let original = try XCTUnwrap(fixture.store.installedModel())
        XCTAssertEqual(try Data(contentsOf: original.fileURL), Data("original".utf8))
      }
    }
  }

  func testFailedFirstImportDoesNotPublishMetadataOrLeavePartialFiles() throws {
    for failure in InstallationFailure.allCases {
      let fixture = try makeFixture()
      let input = try fixture.input(id: "first", bytes: "first")
      XCTAssertThrowsError(try fixture.store(using: failure.operations).install(input))
      XCTAssertNil(fixture.store.installedModel())
      XCTAssertTrue(fixture.store.installedModels().isEmpty)
      XCTAssertTrue(try fixture.snapshot().isEmpty)
    }
  }

  func testOccupiedDestinationIsNeverOverwrittenOrDeletedOnMoveFailure() throws {
    let fixture = try makeFixture()
    let selected = try fixture.store.install(fixture.input(id: "selected", bytes: "selected"))
    let before = try fixture.snapshot()
    var operations = LocalModelInstallationStore.FileOperations()
    operations.moveItem = { source, destination in
      try Data("pre-existing destination".utf8).write(to: destination)
      try FileManager.default.moveItem(at: source, to: destination)
    }
    let input = try fixture.input(id: "new", bytes: "new")
    XCTAssertThrowsError(try fixture.store(using: operations).install(input))
    let after = try fixture.snapshot()
    for (name, data) in before { XCTAssertEqual(after[name], data) }
    let occupied = after.filter { before[$0.key] == nil }
    XCTAssertEqual(occupied.count, 1)
    XCTAssertEqual(occupied.values.first, Data("pre-existing destination".utf8))
    XCTAssertEqual(fixture.store.installedModel(), selected)
  }

  func testFailedSelectionSaveKeepsPreviousSelection() throws {
    let fixture = try makeFixture()
    let first = try fixture.store.install(fixture.input(id: "first", bytes: "first"))
    let selected = try fixture.store.install(fixture.input(id: "selected", bytes: "selected"))
    let before = try fixture.snapshot()
    XCTAssertThrowsError(try fixture.store(using: InstallationFailure.metadata.operations).selectModel(id: first.id))
    XCTAssertEqual(try fixture.snapshot(), before)
    XCTAssertEqual(fixture.store.installedModel(), selected)
  }

  func testCorruptMetadataCannotBeSilentlyReplacedWithANewLibrary() throws {
    let fixture = try makeFixture()
    let selected = try fixture.store.install(fixture.input(id: "selected", bytes: "selected"))
    let validMetadata = try Data(contentsOf: fixture.recordURL)
    try Data("{incomplete".utf8).write(to: fixture.recordURL)
    let before = try fixture.snapshot()
    let input = try fixture.input(id: "new", bytes: "new")
    XCTAssertThrowsError(try fixture.store.install(input))
    XCTAssertThrowsError(try fixture.store.selectModel(id: selected.id))
    XCTAssertEqual(try fixture.snapshot(), before)
    try validMetadata.write(to: fixture.recordURL, options: .atomic)
    XCTAssertEqual(fixture.store.installedModel(), selected)
    XCTAssertEqual(try Data(contentsOf: selected.fileURL), Data("selected".utf8))
  }

  func testCleanupFailureAfterCommitLeavesTheNewModelUsable() throws {
    let fixture = try makeFixture()
    let original = try fixture.store.install(fixture.input(id: "model", bytes: "original"))
    var operations = LocalModelInstallationStore.FileOperations()
    operations.removeItem = { url in
      if url == original.fileURL { throw CocoaError(.fileWriteNoPermission) }
      try FileManager.default.removeItem(at: url)
    }
    let replacement = try fixture.store(using: operations).install(fixture.input(id: "model", bytes: "replacement"))
    XCTAssertEqual(fixture.store.installedModel(), replacement)
    XCTAssertEqual(fixture.store.installedModels(), [replacement])
    XCTAssertEqual(try Data(contentsOf: replacement.fileURL), Data("replacement".utf8))
    XCTAssertEqual(try Data(contentsOf: original.fileURL), Data("original".utf8))
  }

  func testRollbackCleanupFailureDoesNotInvalidateThePreviousModel() throws {
    let fixture = try makeFixture()
    let selected = try fixture.store.install(fixture.input(id: "model", bytes: "original"))
    let metadata = try Data(contentsOf: fixture.recordURL)
    var operations = InstallationFailure.metadata.operations
    operations.removeItem = { _ in throw CocoaError(.fileWriteNoPermission) }
    let input = try fixture.input(id: "model", bytes: "replacement")
    XCTAssertThrowsError(try fixture.store(using: operations).install(input))
    XCTAssertEqual(try Data(contentsOf: fixture.recordURL), metadata)
    XCTAssertEqual(fixture.store.installedModels(), [selected])
    XCTAssertEqual(fixture.store.installedModel(), selected)
    XCTAssertEqual(try Data(contentsOf: selected.fileURL), Data("original".utf8))
  }

  func testConcurrentStoreInstancesDoNotLoseLibraryEntries() async throws {
    let fixture = try makeFixture()
    let inputs = try (0..<8).map { try fixture.input(id: "model.\($0)", bytes: "bytes \($0)") }
    let installed = try await withThrowingTaskGroup(of: LocalModel.self) { group in
      for input in inputs {
        group.addTask { try fixture.store.install(input) }
      }
      var results: [LocalModel] = []
      for try await model in group { results.append(model) }
      return results
    }
    XCTAssertEqual(Set(fixture.store.installedModels().map(\.id)), Set(inputs.map(\.id)))
    XCTAssertEqual(Set(installed.map(\.fileURL)).count, inputs.count)
    for input in inputs {
      try fixture.store.selectModel(id: input.id)
      let selected = try XCTUnwrap(fixture.store.installedModel())
      XCTAssertEqual(try Data(contentsOf: selected.fileURL), try Data(contentsOf: input.fileURL))
    }
  }

  private func makeFixture() throws -> InstallationFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "ModelIdentityTests-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let fixture = InstallationFixture(root: root)
    try FileManager.default.createDirectory(at: fixture.modelsURL, withIntermediateDirectories: true)
    return fixture
  }
}

private enum InstallationFailure: CaseIterable {
  case copy, move, metadata

  var operations: LocalModelInstallationStore.FileOperations {
    var operations = LocalModelInstallationStore.FileOperations()
    switch self {
    case .copy:
      operations.copyItem = { _, destination in
        try Data("partial copy".utf8).write(to: destination)
        throw CocoaError(.fileWriteOutOfSpace)
      }
    case .move:
      operations.moveItem = { _, _ in throw CocoaError(.fileWriteNoPermission) }
    case .metadata:
      operations.writeMetadata = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
    }
    return operations
  }
}

private struct FixtureRecord: Codable, Sendable {
  let id: String
  let displayName: String
  let fileName: String
}

private struct FixtureLibrary: Codable, Sendable {
  let selectedModelID: String?
  let models: [FixtureRecord]
}

private struct InstallationFixture: Sendable {
  let root: URL
  var modelsURL: URL { root.appending(path: "models", directoryHint: .isDirectory) }
  var recordURL: URL { modelsURL.appending(path: "installed-model.json") }
  var store: LocalModelInstallationStore { LocalModelInstallationStore(modelsDirectory: modelsURL) }

  func store(using operations: LocalModelInstallationStore.FileOperations) -> LocalModelInstallationStore {
    LocalModelInstallationStore(modelsDirectory: modelsURL, fileOperations: operations)
  }

  func input(id: String, bytes: String, name: String = "\(UUID().uuidString).gguf") throws -> LocalModel {
    let url = root.appending(path: name)
    try Data(bytes.utf8).write(to: url)
    return LocalModel(id: id, displayName: id, fileURL: url)
  }

  func snapshot() throws -> [String: Data] {
    let files = try FileManager.default.contentsOfDirectory(at: modelsURL, includingPropertiesForKeys: nil)
    return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
  }

  func writeLibrary(_ records: [FixtureRecord], selected: String) throws {
    try JSONEncoder().encode(FixtureLibrary(selectedModelID: selected, models: records))
      .write(to: recordURL, options: .atomic)
  }
}
