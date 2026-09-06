import XCTest
@testable import PrimaryAgent

final class FileModeRuntimeTests: XCTestCase {
  /// Opt-in integration uses only a disposable selected workspace. Test-only edit access does not
  /// add this model to the production trust allowlist.
  func testRealLocalModelReadsWritesAndUndoesDisposableFixture() async throws {
    guard let path = ProcessInfo.processInfo.environment["AI_SPOTLIGHT_FILE_TEST_MODEL_PATH"] else {
      throw XCTSkip("Set AI_SPOTLIGHT_FILE_TEST_MODEL_PATH to run the real local File Mode smoke test.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Fixture")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("before".utf8).write(to: project.appendingPathComponent("fixture.txt"))
    let workspace = try WorkspaceService(selection: .init(attachments: [.select(project)]), accessLevel: .readWrite,
      journalDirectory: root.appendingPathComponent("Recovery"))
    let engine = LlamaServerVisionEngine()
    let model = LocalModel(id: "file-mode-smoke", displayName: "File Mode test model", fileURL: URL(fileURLWithPath: path))
    do {
      try await LocalFileAgent(inference: engine).run(messages: [.init(role: .user, content:
        "Use list_files and read_file to inspect fixture.txt. Replace the entire contents of that existing file with exactly the lowercase word \"after\" (five letters, no newline). Call write_file with path \"fixture.txt\" and content \"after\". Read it again to verify. Do not create other files.")],
        model: model, tools: AgentFileTools(workspace: workspace)) { _ in }
      await engine.unload()
    } catch { await engine.unload(); throw error }
    let edited = try await workspace.readFile("fixture.txt")
    XCTAssertEqual(edited, "after")
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 1)
    _ = try await workspace.undo(changes)
    let restored = try await workspace.readFile("fixture.txt")
    XCTAssertEqual(restored, "before")
  }
}
