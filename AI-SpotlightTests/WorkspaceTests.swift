import Darwin
import XCTest
@testable import Enigma

final class WorkspaceTests: XCTestCase {
  private var root: URL!
  private var project: URL!
  private var journal: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    project = root.appendingPathComponent("Project")
    journal = root.appendingPathComponent("Recovery")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("original text\nneedle\n".utf8).write(to: project.appendingPathComponent("notes.txt"))
    try Data("private".utf8).write(to: root.appendingPathComponent("private.txt"))
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func service(file: Bool = false, level: FileAccessLevel = .readWrite,
                       failure: (@Sendable (Int) throws -> Void)? = nil) throws -> WorkspaceService {
    let attachment = try WorkspaceAttachment.select(file ? project.appendingPathComponent("notes.txt") : project)
    return try WorkspaceService(selection: WorkspaceSelection(attachments: [attachment]),
      accessLevel: level, journalDirectory: journal, failureAfterWrite: failure)
  }

  func testSelectAndReadIndividualFileWithoutSiblingAccess() async throws {
    let workspace = try service(file: true)
    let listing = try await workspace.listFiles()
    XCTAssertEqual(listing, ["notes.txt"])
    let text = try await workspace.readFile("notes.txt")
    XCTAssertTrue(text.contains("original"))
    do { _ = try await workspace.readFile("private.txt"); XCTFail() }
    catch { XCTAssertEqual(error as? FileModeError, .outsideWorkspace) }
    do { try await workspace.apply([.create(path: "new.txt", content: "no")]); XCTFail() }
    catch { XCTAssertEqual(error as? FileModeError, .outsideWorkspace) }
  }

  func testSelectFolderAndSearchNamesAndText() async throws {
    let workspace = try service()
    let listing = try await workspace.listFiles()
    XCTAssertTrue(listing.contains("notes.txt"))
    let results = try await workspace.searchFiles("needle")
    XCTAssertEqual(results, ["notes.txt:2: needle"])
    let names = try await workspace.searchFiles("notes", namesOnly: true)
    XCTAssertEqual(names, ["notes.txt"])
  }

  func testTextSearchIncludesContentBeyondReadPreviewLimit() async throws {
    try Data((String(repeating: "first line filler ", count: 2_500) + "\nlate needle\n").utf8)
      .write(to: project.appendingPathComponent("long.txt"))
    let workspace = try service()
    let results = try await workspace.searchFiles("late needle")
    XCTAssertEqual(results, ["long.txt:2: late needle"])
  }

  func testRejectTraversalAbsolutePathsAndSymlinkEscapes() async throws {
    try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape"), withDestinationURL: root)
    try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("private.txt"))
    let workspace = try service()
    for path in ["../private.txt", "sub/../../private.txt", root.appendingPathComponent("private.txt").path,
                 "escape/private.txt", "link.txt"] {
      do { _ = try await workspace.readFile(path); XCTFail("Read escaped: \(path)") } catch {}
      do { try await workspace.apply([.write(path: path, content: "bad")]); XCTFail("Write escaped: \(path)") } catch {}
    }
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("private.txt"), encoding: .utf8), "private")
    let listing = try await workspace.listFiles()
    XCTAssertEqual(listing, ["notes.txt"])
  }

  func testRejectHardLinksSpecialFilesAndProtectedSettings() async throws {
    try FileManager.default.linkItem(at: root.appendingPathComponent("private.txt"), to: project.appendingPathComponent("hard.txt"))
    XCTAssertEqual(mkfifo(project.appendingPathComponent("pipe").path, 0o600), 0)
    try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: false)
    let workspace = try service()
    for path in ["hard.txt", "pipe"] {
      do { _ = try await workspace.readFile(path); XCTFail(path) } catch {}
    }
    do { try await workspace.apply([.create(path: ".git/config", content: "no")]); XCTFail() }
    catch { XCTAssertEqual(error as? FileModeError, .unsafeFile) }
  }

  func testLocalReadOnlyRejectsEveryMutation() async throws {
    let workspace = try service(level: .readOnly)
    let mutations: [WorkspaceMutation] = [.write(path: "notes.txt", content: "no"),
      .append(path: "notes.txt", content: "no"),
      .patch(path: "notes.txt", old: "original", new: "no"), .create(path: "new.txt", content: "no"),
      .move(from: "notes.txt", to: "renamed.txt"), .delete(path: "notes.txt")]
    for mutation in mutations {
      do { try await workspace.apply([mutation]); XCTFail() }
      catch { XCTAssertEqual(error as? FileModeError, .readOnly) }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  func testSnapshotPrecedesWriteAndUndoRestoresModifiedDeletedCreatedAndMovedFiles() async throws {
    try Data("delete me".utf8).write(to: project.appendingPathComponent("delete.txt"))
    try Data("move me".utf8).write(to: project.appendingPathComponent("move.txt"))
    let journalRoot = journal!
    let workspace = try service(failure: { _ in
      XCTAssertEqual(WorkspaceService.savedChanges(in: journalRoot).count, 1, "Snapshot must exist before any write")
    })
    try await workspace.apply([.patch(path: "notes.txt", old: "original", new: "changed"),
      .delete(path: "delete.txt"), .create(path: "new.txt", content: "new"), .move(from: "move.txt", to: "moved.txt")])
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 5)
    XCTAssertEqual(WorkspaceService.savedChanges(in: journal).first, changes)
    // A fresh service simulates restoring a durable journal after app restart.
    let recovery = try WorkspaceService(selection: changes.selection, accessLevel: .readWrite, journalDirectory: journal)
    let undone = try await recovery.undo(changes)
    XCTAssertTrue(undone.isUndone)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8), "original text\nneedle\n")
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("delete.txt"), encoding: .utf8), "delete me")
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("move.txt"), encoding: .utf8), "move me")
    XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("new.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("moved.txt").path))
  }

  func testFailedPartialEditRollsBackEntireOperation() async throws {
    let workspace = try service(failure: { count in if count == 1 { throw FileModeError.operation("Injected failure") } })
    do {
      try await workspace.apply([.create(path: "a-new.txt", content: "new"), .write(path: "notes.txt", content: "changed")])
      XCTFail()
    } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("a-new.txt").path))
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8), "original text\nneedle\n")
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 0)
  }

  func testUndoPreservesNewerUserChangesAndFirstSnapshotAcrossWrites() async throws {
    let workspace = try service()
    try await workspace.apply([.write(path: "notes.txt", content: "first")])
    try await workspace.apply([.write(path: "notes.txt", content: "second")])
    let changes = await workspace.changeSet()
    XCTAssertEqual(String(data: changes.changes[0].before.data!, encoding: .utf8), "original text\nneedle\n")
    try Data("user changes".utf8).write(to: project.appendingPathComponent("notes.txt"))
    do { _ = try await workspace.undo(changes); XCTFail() }
    catch { XCTAssertEqual(error as? FileModeError, .conflict) }
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8), "user changes")
  }

  func testFailedRollbackPreservesConcurrentEditAndDurableRecoveryCopies() async throws {
    let file = project.appendingPathComponent("notes.txt")
    let original = try Data(contentsOf: file)
    let workspace = try service(failure: { count in
      if count == 1 {
        try Data("newer external edit".utf8).write(to: file)
        throw FileModeError.operation("Injected failure after external edit")
      }
    })
    do {
      try await workspace.apply([.write(path: "notes.txt", content: "agent edit"),
        .create(path: "z-new.txt", content: "not written")])
      XCTFail("Unsafe rollback must stop and retain recovery")
    } catch { XCTAssertTrue(error.localizedDescription.contains("could not be restored")) }
    XCTAssertEqual(try Data(contentsOf: file), Data("newer external edit".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("z-new.txt").path))
    let snapshot = await workspace.snapshotURL
    let saved = try JSONDecoder().decode(WorkspaceChangeSet.self, from: Data(contentsOf: snapshot))
    XCTAssertEqual(saved.changes.first { $0.path == "notes.txt" }?.before.data, original)
    do { _ = try await workspace.undo(saved); XCTFail("Undo must also preserve the external edit") }
    catch { XCTAssertEqual(error as? FileModeError, .conflict) }
    XCTAssertEqual(try Data(contentsOf: file), Data("newer external edit".utf8))
  }

  func testEditsAndUndoPreserveFinderMetadataAndFilePermissions() async throws {
    let file = project.appendingPathComponent("notes.txt")
    let tag = Data("fixture-tag".utf8)
    XCTAssertEqual(tag.withUnsafeBytes { setxattr(file.path, "com.ai-spotlight.test", $0.baseAddress, tag.count, 0, 0) }, 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    let workspace = try service()
    try await workspace.apply([.write(path: "notes.txt", content: "Edited")])
    var bytes = Data(count: tag.count)
    XCTAssertEqual(bytes.withUnsafeMutableBytes { getxattr(file.path, "com.ai-spotlight.test", $0.baseAddress, tag.count, 0, 0) }, tag.count)
    XCTAssertEqual(bytes, tag)
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.changes.first?.before.attributes["com.ai-spotlight.test"], tag)
    _ = try await workspace.undo(changes)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
  }

  func testEditsAndUndoRetainExplicitMacOSAccessRules() async throws {
    let file = project.appendingPathComponent("notes.txt")
    // A restrictive, harmless ACL provides a stable metadata fixture without giving anyone access.
    let text = "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:writeattr\n"
    let acl = try XCTUnwrap(acl_from_text(text))
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    XCTAssertEqual(acl_set_file(file.path, ACL_TYPE_EXTENDED, acl), 0)
    let workspace = try service()
    let access = try WorkspaceAccess(selection: workspace.selection)
    let path = try access.location("notes.txt")
    let original = try access.permissions(path)
    XCTAssertNotNil(original.acl)
    try await workspace.apply([.write(path: "notes.txt", content: "Edited")])
    XCTAssertEqual(try access.permissions(path), original)
    let changes = await workspace.changeSet()
    _ = try await workspace.undo(changes)
    XCTAssertEqual(try access.permissions(path), original)
  }

  func testIndividualFileCanBeReopenedAfterEditAndRecoveredAfterDeletion() async throws {
    let workspace = try service(file: true)
    try await workspace.apply([.write(path: "notes.txt", content: "Edited")])
    let selection = workspace.selection
    let reopened = try WorkspaceService(selection: selection, accessLevel: .readWrite, journalDirectory: journal)
    let text = try await reopened.readFile("notes.txt")
    XCTAssertEqual(text, "Edited")
    try await reopened.apply([.delete(path: "notes.txt")])
    let deleted = await reopened.changeSet()
    let recovery = try WorkspaceService(selection: selection, accessLevel: .readWrite, journalDirectory: journal)
    _ = try await recovery.undo(deleted)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8), "Edited")
  }

  func testCaseAliasesCannotCreateConflictingUndoEntries() async throws {
    let workspace = try service()
    do { try await workspace.apply([.write(path: "NOTES.txt", content: "alias")]); XCTFail() } catch {}
    let text = try await workspace.readFile("notes.txt")
    XCTAssertEqual(text, "original text\nneedle\n")
  }

  func testAmbiguousPatchAndInvalidLaterMutationLeaveAllFilesUntouched() async throws {
    let workspace = try service()
    do {
      try await workspace.apply([.write(path: "notes.txt", content: "valid first"),
        .patch(path: "notes.txt", old: "not present", new: "bad")])
      XCTFail()
    } catch {}
    let text = try await workspace.readFile("notes.txt")
    XCTAssertEqual(text, "original text\nneedle\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  func testRevocationRejectsLateReadsAndWrites() async throws {
    let workspace = try service()
    await workspace.revoke()
    do { _ = try await workspace.readFile("notes.txt"); XCTFail() }
    catch { XCTAssertEqual(error as? FileModeError, .inactive) }
    do { try await workspace.apply([.write(path: "notes.txt", content: "late")]); XCTFail() }
    catch { XCTAssertEqual(error as? FileModeError, .inactive) }
  }

  func testQueryExcerptFindsLateTextWithBoundedUnicodeOffsets() async throws {
    let content = String(repeating: "🌿 Keep this line.\n", count: 4_000) + "Target: before\n"
    try Data(content.utf8).write(to: project.appendingPathComponent("notes.txt"))
    let workspace = try service()
    let excerpt = try await workspace.readExcerpt("notes.txt", query: "Target: before")
    XCTAssertTrue(excerpt["text"].string!.contains("Target: before"))
    XCTAssertLessThanOrEqual(excerpt["text"].string!.count, 2_000)
    XCTAssertEqual(excerpt["total_characters"].integer, content.count)
    XCTAssertEqual(excerpt["has_more"].bool, false)
    let offset = try XCTUnwrap(excerpt["offset"].integer)
    XCTAssertEqual(excerpt["text"].string, String(content.dropFirst(offset)))
    try await workspace.apply([.patch(path: "notes.txt", old: "Target: before", new: "Target: after")])
    try await workspace.verifyChanges()
    _ = try await workspace.undo(workspace.changeSet())
    XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("notes.txt")), Data(content.utf8))
  }

  func testFirstWriteRejectsConcurrentChangesSinceRead() async throws {
    for mutation in [WorkspaceMutation.write(path: "notes.txt", content: "new"),
      .patch(path: "notes.txt", old: "original", new: "new")] {
      let workspace = try service()
      try Data("original".utf8).write(to: project.appendingPathComponent("notes.txt"))
      _ = try await workspace.readFile("notes.txt")
      try Data("original plus user work".utf8).write(to: project.appendingPathComponent("notes.txt"))
      do { try await workspace.apply([mutation]); XCTFail("Do not overwrite a newer file") }
      catch { XCTAssertEqual(error as? FileModeError, .conflict) }
      let changes = await workspace.changeSet()
      XCTAssertEqual(changes.count, 0)
      XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8), "original plus user work")
    }
  }

  func testReadAliasesCannotHideConcurrentChangesFromFirstWrite() async throws {
    for alias in ["./notes.txt", "NOTES.TXT"] {
      let workspace = try service()
      try Data("original".utf8).write(to: project.appendingPathComponent("notes.txt"))
      _ = try await workspace.readFile(alias)
      try Data("original plus user work".utf8).write(to: project.appendingPathComponent("notes.txt"))
      do { try await workspace.apply([.write(path: "notes.txt", content: "new")]); XCTFail() }
      catch { XCTAssertEqual(error as? FileModeError, .conflict) }
    }
  }

  func testVerificationDetectsExternalChangesWithoutRollingThemBack() async throws {
    let workspace = try service()
    try await workspace.apply([.write(path: "notes.txt", content: "agent edit")])
    try Data("newer user text".utf8).write(to: project.appendingPathComponent("notes.txt"))
    do { try await workspace.verifyChanges(); XCTFail("A journal alone cannot prove current contents") }
    catch { XCTAssertEqual(error as? FileModeError, .conflict) }
    let changes = await workspace.changeSet()
    do { _ = try await workspace.undo(changes); XCTFail("Undo must preserve concurrent user text") }
    catch { XCTAssertEqual(error as? FileModeError, .conflict) }
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8), "newer user text")
    XCTAssertEqual(changes.changes.first?.before.data, Data("original text\nneedle\n".utf8))
  }

  func testPatchErrorsDistinguishMissingAndAmbiguousMatches() async throws {
    let workspace = try service()
    for (old, expected) in [("missing", FileModeError.patchNotFound), ("e", .patchAmbiguous)] {
      do { try await workspace.apply([.patch(path: "notes.txt", old: old, new: "x")]); XCTFail() }
      catch { XCTAssertEqual(error as? FileModeError, expected) }
    }
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 0)
  }

  func testLocalPatchMustUseAnObservedExcerptInsteadOfGuessingUnseenText() async throws {
    let initial = String(repeating: "Unchanged line\n", count: 1_000) + "Status: before.\n"
    try Data(initial.utf8).write(to: project.appendingPathComponent("notes.txt"))
    let workspace = try service()
    _ = try await workspace.readExcerpt("notes.txt", limit: 500)
    do {
      try await workspace.apply([.patch(path: "notes.txt", old: "Status:", new: "Status: after.")], requireObservedPatch: true)
      XCTFail("A guessed match outside the excerpt must not run")
    } catch { XCTAssertEqual(error as? FileModeError, .patchUnobserved) }
    XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("notes.txt")), Data(initial.utf8))
    _ = try await workspace.readExcerpt("./notes.txt", query: "Status:")
    try await workspace.apply([.patch(path: "notes.txt", old: "Status: before.", new: "Status: after.")], requireObservedPatch: true)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8),
      initial.replacingOccurrences(of: "Status: before.", with: "Status: after."))
  }

  func testQuerySearchesTheWholeFileEvenAfterAnEarlierExcerptOffset() async throws {
    let workspace = try service()
    let excerpt = try await workspace.readExcerpt("notes.txt", offset: 20, query: "original")
    XCTAssertEqual(excerpt["text"].string, "original text\nneedle\n")
    let unfiltered = try await workspace.readExcerpt("notes.txt", query: "")
    XCTAssertEqual(unfiltered["text"], excerpt["text"])
    let missing = try await workspace.metadata("absent.txt")
    XCTAssertEqual(missing["exists"].bool, false)
  }

  func testSearchResultsAreObservedTextForLocalPatches() async throws {
    let workspace = try service()
    _ = try await workspace.searchFiles("original")
    try await workspace.apply([.patch(path: "notes.txt", old: "original text", new: "changed text")], requireObservedPatch: true)
    let text = try await workspace.readFile("notes.txt")
    XCTAssertEqual(text, "changed text\nneedle\n")
  }

  func testAppendKeepsProtectedWritePolicyAndFileSizeLimit() async throws {
    let workspace = try WorkspaceService(selection: .init(attachments: [.select(project)]), accessLevel: .readWrite,
      journalDirectory: journal, writePolicy: .local(cloudAvailability: { .available(modelID: "test") }, notice: { _ in }))
    try Data("let value = 1\n".utf8).write(to: project.appendingPathComponent("source.swift"))
    do { try await workspace.apply([.append(path: "source.swift", content: "let other = 2\n")]); XCTFail() }
    catch { XCTAssertEqual(error as? FileModeError, .protectedWriteRequiresCloud) }
    do {
      try await workspace.apply([.append(path: "notes.txt", content: String(repeating: "a", count: WorkspaceAccess.fileLimit))])
      XCTFail()
    } catch { XCTAssertEqual(error as? FileModeError, .tooLarge) }
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 0)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("source.swift"), encoding: .utf8), "let value = 1\n")
  }
}
