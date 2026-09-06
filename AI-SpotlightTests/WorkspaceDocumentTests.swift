import AppKit
import XCTest
@testable import PrimaryAgent

final class WorkspaceDocumentTests: XCTestCase {
  private let original = Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}{\colortbl;\red255\green0\blue0;}\paperw12240\paperh15840\margl1440\margr1440\f0\fs24 Heading\par \b before\b0  and \cf1 coloured\cf0  text.}"#.utf8)

  private func fixture(policy: WorkspaceWritePolicy = .cloud,
                       failure: (@Sendable (Int) throws -> Void)? = nil) throws -> (URL, WorkspaceService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try original.write(to: project.appendingPathComponent("note.rtf"))
    let workspace = try WorkspaceService(selection: .init(attachments: [.select(project)]), accessLevel: .readWrite,
      journalDirectory: root.appendingPathComponent("Recovery"), writePolicy: policy, failureAfterWrite: failure)
    return (root, workspace)
  }

  func testRTFReadAndSearchExposeVisibleText() async throws {
    let (root, workspace) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = try await workspace.readFile("note.rtf")
    XCTAssertEqual(text, "Heading\nbefore and coloured text.")
    let matches = try await workspace.searchFiles("before and")
    XCTAssertEqual(matches, ["note.rtf:2: before and coloured text."])
  }

  func testRTFPatchPreservesFormattingAndUndoRestoresExactBytesAfterRestart() async throws {
    let (root, workspace) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = await AgentFileTools(workspace: workspace).execute(name: "apply_patch", arguments: .object([
      "path": .string("note.rtf"), "old_text": .string("before"), "new_text": .string("after 👋")]))
    XCTAssertTrue(result.success, result.text)
    let saved = try Data(contentsOf: root.appendingPathComponent("Project/note.rtf"))
    let decoded = try XCTUnwrap(NSAttributedString(rtf: saved, documentAttributes: nil))
    XCTAssertEqual(decoded.string, "Heading\nafter 👋 and coloured text.")
    let bold = try XCTUnwrap(decoded.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)
    XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
    let colorIndex = (decoded.string as NSString).range(of: "coloured").location
    let color = try XCTUnwrap((decoded.attribute(.foregroundColor, at: colorIndex, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB))
    let beforeDocument = try XCTUnwrap(NSAttributedString(rtf: original, documentAttributes: nil))
    let beforeIndex = (beforeDocument.string as NSString).range(of: "coloured").location
    let beforeColor = try XCTUnwrap((beforeDocument.attribute(.foregroundColor, at: beforeIndex, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB))
    XCTAssertEqual(color.redComponent, beforeColor.redComponent, accuracy: 0.01)
    XCTAssertEqual(color.greenComponent, beforeColor.greenComponent, accuracy: 0.01)
    XCTAssertEqual(color.blueComponent, beforeColor.blueComponent, accuracy: 0.01)
    let snapshot = await workspace.snapshotURL
    let record = try JSONDecoder().decode(WorkspaceChangeSet.self, from: Data(contentsOf: snapshot))
    XCTAssertEqual(record.changes.first?.before.data, original)
    XCTAssertEqual(record.changes.first?.after.data, saved)
    let reopened = try WorkspaceService(selection: record.selection, accessLevel: .readWrite,
      journalDirectory: root.appendingPathComponent("Recovery"))
    _ = try await reopened.undo(record)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Project/note.rtf")), original)
  }

  func testRTFReplacementAndCreationKeepRichTextFormat() async throws {
    let (root, workspace) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await workspace.apply([.write(path: "note.rtf", content: "Heading\nafter and coloured text."),
      .create(path: "new.rtf", content: "New {note} \\ café 👋")])
    let saved = try Data(contentsOf: root.appendingPathComponent("Project/note.rtf"))
    XCTAssertTrue(saved.starts(with: Data(#"{\rtf"#.utf8)))
    let text = try await workspace.readFile("new.rtf")
    XCTAssertEqual(text, "New {note} \\ café 👋")
    let record = await workspace.changeSet()
    _ = try await workspace.undo(record)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Project/new.rtf").path))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Project/note.rtf")), original)
  }

  func testLocalRTFRequiresCloudConsentOrUsesDisclosedFallback() async throws {
    for available in [true, false] {
      let notice = expectation(description: "Protected RTF policy is disclosed")
      let (root, workspace) = try fixture(policy: .local(cloudAvailability: {
        available ? .available(modelID: "codex") : .unavailable(reason: "Offline")
      }, notice: { value in
        if available { XCTAssertEqual(value, .cloudRequired(paths: ["note.rtf"], modelID: "codex")) }
        else { XCTAssertEqual(value, .localFallback(paths: ["note.rtf"], reason: "Offline")) }
        notice.fulfill()
      }))
      defer { try? FileManager.default.removeItem(at: root) }
      let result = await AgentFileTools(workspace: workspace).execute(name: "apply_patch", arguments: .object([
        "path": .string("note.rtf"), "old_text": .string("before"), "new_text": .string("after")]))
      XCTAssertEqual(result.success, !available)
      XCTAssertEqual(result.requiresCloudConsent, available)
      await fulfillment(of: [notice], timeout: 1)
      let text = try await workspace.readFile("note.rtf")
      XCTAssertTrue(text.contains(available ? "before" : "after"))
      let record = await workspace.changeSet()
      if !available { _ = try await workspace.undo(record) }
      XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Project/note.rtf")), original)
    }
    XCTAssertEqual(WorkspaceWriteClassifier.classify(path: "disguised.txt", data: original, createdBySpotlight: false), .protectedWrite)
  }

  func testRTFReplacementsRespectUnicodeCharacterBoundaries() throws {
    for (before, after) in [("👨 hello", "👩 hello"), ("café 👋", "café 🌈"), ("", "New 👋"),
      ("Remove all", ""), ("heading\nbefore\nend", "heading\nafter\nend")] {
      let data = try WorkspaceDocument.create(path: "note.rtf", content: before)
      let edited = try WorkspaceDocument.edit(path: "note.rtf", data: data, content: after)
      XCTAssertEqual(try WorkspaceDocument.text(path: "note.rtf", data: edited), after)
    }
  }

  func testMalformedRTFComplexContentAndAmbiguousPatchesLeaveFileUntouched() throws {
    for data in [Data("plain text mislabeled as rich text".utf8),
      Data(#"{\rtf1\ansi before {\pict\pngblip 00}}"#.utf8),
      Data(#"{\rtf1\ansi before {\field{\*\fldinst INCLUDETEXT other.txt}}}"#.utf8)] {
      XCTAssertThrowsError(try WorkspaceDocument.edit(path: "bad.rtf", data: data, content: "replacement"))
    }
    let duplicate = try WorkspaceDocument.create(path: "note.rtf", content: "before before")
    XCTAssertThrowsError(try WorkspaceDocument.edit(path: "note.rtf", data: duplicate, oldText: "before", content: "after"))
    XCTAssertThrowsError(try WorkspaceDocument.edit(path: "note.rtf", data: original, oldText: #"\b before"#, content: "after"))
    XCTAssertThrowsError(try WorkspaceDocument.edit(path: "note.rtf", data: original, content: "bad\0text"))
    XCTAssertEqual(try WorkspaceDocument.edit(path: "note.rtf", data: original, content: "Heading\nbefore and coloured text."), original)
  }

  func testFailedPartialRTFTransactionRollsBackOriginalBytes() async throws {
    let (root, workspace) = try fixture(failure: { if $0 == 1 { throw FileModeError.operation("Injected failure") } })
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      try await workspace.apply([.patch(path: "note.rtf", old: "before", new: "after"), .create(path: "z-new.rtf", content: "new")])
      XCTFail("Expected rollback")
    } catch { }
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Project/note.rtf")), original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Project/z-new.rtf").path))
  }
}
