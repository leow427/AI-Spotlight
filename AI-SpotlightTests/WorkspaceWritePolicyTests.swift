import XCTest
@testable import Enigma

final class WorkspaceWritePolicyTests: XCTestCase {
  private var root: URL!
  private var folder: URL!
  private var recovery: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    folder = root.appendingPathComponent("Project")
    recovery = root.appendingPathComponent("Recovery")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("before".utf8).write(to: folder.appendingPathComponent("notes.md"))
    try Data("let before = true".utf8).write(to: folder.appendingPathComponent("code.swift"))
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func service(_ policy: WorkspaceWritePolicy, failure: (@Sendable (Int) throws -> Void)? = nil) throws -> WorkspaceService {
    try WorkspaceService(selection: .init(attachments: [.select(folder)]), accessLevel: .readWrite,
      journalDirectory: recovery, writePolicy: policy, failureAfterWrite: failure)
  }

  func testCentralClassificationUsesConservativeTypesAndSensitiveNames() {
    for path in ["notes.md", "PLAN.TXT", "checklist", "readme", "notes.markdown"] {
      XCTAssertEqual(WorkspaceWriteClassifier.classify(path: path, data: Data("plain notes".utf8), createdBySpotlight: false), .safeWrite, path)
    }
    for path in ["main.swift", "config.json", "project.pbxproj", "data.csv", "unknown.dat", "AGENTS.md", "secrets.txt", ".settings/notes.md", "config.md", "settings/notes.txt"] {
      XCTAssertEqual(WorkspaceWriteClassifier.classify(path: path, data: Data("plain text".utf8), createdBySpotlight: false), .protectedWrite, path)
    }
    for text in ["{\"setting\":true}", "#!/bin/sh\necho hi", "<?xml version=\"1.0\"?>"] {
      XCTAssertEqual(WorkspaceWriteClassifier.classify(path: "notes.txt", data: Data(text.utf8), createdBySpotlight: false), .protectedWrite)
    }
    XCTAssertEqual(WorkspaceWriteClassifier.classify(path: "scratch.custom", data: Data("app creation".utf8), createdBySpotlight: true), .safeWrite)
    XCTAssertEqual(WorkspaceWriteClassifier.classify(path: "credentials.txt", data: Data("app creation".utf8), createdBySpotlight: true), .protectedWrite)
  }

  func testSafeLocalWritesNeverCheckCloudAndRemainUndoable() async throws {
    let audit = WritePolicyAudit()
    let workspace = try service(audit.policy(.available(modelID: "codex")))
    try await workspace.apply([.write(path: "notes.md", content: "edited"), .create(path: "checklist.txt", content: "one task")])
    let checks = await audit.checks
    XCTAssertEqual(checks, 0)
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 2)
    _ = try await workspace.undo(changes)
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8), "before")
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("checklist.txt").path))
  }

  func testProtectedLocalEditWaitsForCloudPermissionWithoutWriting() async throws {
    let audit = WritePolicyAudit()
    let workspace = try service(audit.policy(.available(modelID: "codex")))
    do {
      try await workspace.apply([.write(path: "notes.md", content: "must not partially edit"), .write(path: "code.swift", content: "changed")])
      XCTFail()
    } catch { XCTAssertEqual(error as? FileModeError, .protectedWriteRequiresCloud) }
    let notices = await audit.notices
    XCTAssertEqual(notices, [.cloudRequired(paths: ["code.swift"], modelID: "codex")])
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8), "before")
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("code.swift"), encoding: .utf8), "let before = true")
    XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
  }

  func testUnavailableCloudAllowsNoticedLocalFallbackWithSnapshotAndUndo() async throws {
    let audit = WritePolicyAudit()
    let recovery = recovery!
    let workspace = try service(audit.policy(.unavailable(reason: "Codex is offline.")), failure: { _ in
      XCTAssertEqual(WorkspaceService.savedChanges(in: recovery).count, 1)
    })
    try await workspace.apply([.write(path: "code.swift", content: "local fallback")])
    let notices = await audit.notices
    XCTAssertEqual(notices, [.localFallback(paths: ["code.swift"], reason: "Codex is offline.")])
    XCTAssertTrue(notices.first!.message.contains("less reliable"))
    _ = try await workspace.undo(await workspace.changeSet())
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("code.swift"), encoding: .utf8), "let before = true")
  }

  func testProtectedFallbackFailureRollsBackEveryAffectedFile() async throws {
    let audit = WritePolicyAudit()
    let workspace = try service(audit.policy(.unavailable(reason: "No compatible cloud model.")), failure: { count in
      if count == 1 { throw FileModeError.operation("Injected failure") }
    })
    do {
      try await workspace.apply([.create(path: "a.swift", content: "new"), .write(path: "code.swift", content: "changed")])
      XCTFail()
    } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.swift").path))
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("code.swift"), encoding: .utf8), "let before = true")
  }

  func testCreatedFileProvenanceSurvivesRestartAndRejectsExternalReplacement() async throws {
    let creator = try service(.cloud)
    try await creator.apply([.create(path: "scratch.custom", content: "app created")])
    _ = await creator.finish()
    let audit = WritePolicyAudit()
    let local = try service(audit.policy(.available(modelID: "codex")))
    try await local.apply([.write(path: "scratch.custom", content: "local edit")])
    let checks = await audit.checks
    XCTAssertEqual(checks, 0)
    _ = await local.finish()
    try Data("external replacement".utf8).write(to: folder.appendingPathComponent("scratch.custom"))
    let reopened = try service(audit.policy(.available(modelID: "codex")))
    do { try await reopened.apply([.write(path: "scratch.custom", content: "no")]); XCTFail() }
    catch { XCTAssertEqual(error as? FileModeError, .protectedWriteRequiresCloud) }
  }

  func testNewUnknownFilesAndRenameDestinationsCannotBypassProtectedPolicy() async throws {
    let audit = WritePolicyAudit()
    let workspace = try service(audit.policy(.available(modelID: "codex")))
    try await workspace.apply([.create(path: "scratch.txt", content: "created here")])
    for mutation in [WorkspaceMutation.create(path: "new.swift", content: "source"), .move(from: "scratch.txt", to: "moved.swift"),
      .write(path: "notes.md", content: "{\"config\":true}")] {
      do { try await workspace.apply([mutation]); XCTFail() }
      catch { XCTAssertEqual(error as? FileModeError, .protectedWriteRequiresCloud) }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("moved.swift").path))
  }

  func testCloudEditsProtectedFilesThroughSameTransactionService() async throws {
    let workspace = try service(.cloud)
    try await workspace.apply([.patch(path: "code.swift", old: "true", new: "false")])
    _ = try await workspace.undo(await workspace.changeSet())
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("code.swift"), encoding: .utf8), "let before = true")
  }

  func testProtectedDeletionChecksCloudPolicyBeforeAskingToDeleteLocally() async throws {
    let audit = WritePolicyAudit()
    let workspace = try service(audit.policy(.available(modelID: "codex")))
    do {
      try await workspace.apply([.delete(path: "code.swift")], confirmDeletion: { _ in
        XCTFail("Cloud permission must precede any local deletion confirmation"); return true
      })
      XCTFail()
    } catch { XCTAssertEqual(error as? FileModeError, .protectedWriteRequiresCloud) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("code.swift").path))
  }

  func testRevocationWhileCheckingCloudCannotFallThroughToAWrite() async throws {
    let gate = WritePolicyGate()
    let checking = expectation(description: "Checking cloud metadata")
    let workspace = try service(.local(cloudAvailability: {
      checking.fulfill()
      return await gate.value()
    }, notice: { _ in }))
    let edit = Task { try await workspace.apply([.write(path: "code.swift", content: "must not change")]) }
    await fulfillment(of: [checking], timeout: 3)
    await workspace.revoke()
    await gate.resume()
    do { try await edit.value; XCTFail() }
    catch { XCTAssertEqual(error as? FileModeError, .inactive) }
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("code.swift"), encoding: .utf8), "let before = true")
  }

  func testScopeValidationPrecedesAnyCloudCheck() async throws {
    let audit = WritePolicyAudit()
    let workspace = try service(audit.policy(.available(modelID: "codex")))
    do { try await workspace.apply([.create(path: "../outside.swift", content: "no")]); XCTFail() }
    catch { XCTAssertEqual(error as? FileModeError, .outsideWorkspace) }
    let checks = await audit.checks
    XCTAssertEqual(checks, 0)
  }
}

private actor WritePolicyAudit {
  private(set) var checks = 0
  private(set) var notices: [ProtectedWriteNotice] = []
  nonisolated func policy(_ availability: FileEditingCloudAvailability) -> WorkspaceWritePolicy {
    .local(cloudAvailability: { await self.check(availability) }, notice: { await self.record($0) })
  }
  func check(_ value: FileEditingCloudAvailability) -> FileEditingCloudAvailability { checks += 1; return value }
  func record(_ notice: ProtectedWriteNotice) { notices.append(notice) }
}

private actor WritePolicyGate {
  private var continuation: CheckedContinuation<FileEditingCloudAvailability, Never>?
  private var resumed = false
  func value() async -> FileEditingCloudAvailability {
    if resumed { return .unavailable(reason: "Offline") }
    return await withCheckedContinuation { continuation = $0 }
  }
  func resume() {
    resumed = true
    continuation?.resume(returning: .unavailable(reason: "Offline"))
    continuation = nil
  }
}
