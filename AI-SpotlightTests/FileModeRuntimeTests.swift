import XCTest
@testable import PrimaryAgent

final class FileModeRuntimeTests: XCTestCase {
  /// Opt-in integration uses the production local permission policy in a disposable workspace.
  func testRealLocalModelReadsWritesAndUndoesDisposableFixture() async throws {
    try await runSmoke(fileName: "fixture.txt", policy: .local(cloudAvailability: {
      XCTFail("Safe text edits must not check cloud availability"); return .available(modelID: "unused")
    }, notice: { _ in XCTFail("Safe edit must not trigger protected-write policy") }))
  }

  func testRealLocalModelAttemptsProtectedEditWhenCloudIsUnavailable() async throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["AI_SPOTLIGHT_FILE_TEST_MODEL_PATH"] == nil,
      "Set AI_SPOTLIGHT_FILE_TEST_MODEL_PATH to run the real local File Mode smoke test.")
    let notice = expectation(description: "Local protected fallback disclosed")
    notice.assertForOverFulfill = false
    try await runSmoke(fileName: "fixture.swift", initialContent: "let message = \"before\"\n",
      expectedContent: "let message = \"after\"\n",
      instruction: "Read fixture.swift, then use apply_patch to change only the string literal before to after. Keep the variable name message and the Swift syntax unchanged. Read it again to verify. Do not create or rename files.", policy: .local(cloudAvailability: { .unavailable(reason: "Offline test fixture") },
      notice: { value in
        if case .localFallback = value { notice.fulfill() } else { XCTFail("Expected a local fallback") }
      }))
    await fulfillment(of: [notice], timeout: 1)
  }

  private func runSmoke(fileName: String, initialContent: String = "before", expectedContent: String = "after",
                        instruction: String? = nil, policy: WorkspaceWritePolicy) async throws {
    guard let path = ProcessInfo.processInfo.environment["AI_SPOTLIGHT_FILE_TEST_MODEL_PATH"] else {
      throw XCTSkip("Set AI_SPOTLIGHT_FILE_TEST_MODEL_PATH to run the real local File Mode smoke test.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Fixture")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(initialContent.utf8).write(to: project.appendingPathComponent(fileName))
    let engine = LlamaServerVisionEngine()
    let model = LocalModel(id: "file-mode-smoke", displayName: "File Mode test model", fileURL: URL(fileURLWithPath: path))
    let workspace = try WorkspaceService(selection: .init(attachments: [.select(project)]),
      accessLevel: LocalFileCapabilities.production.access(for: model), journalDirectory: root.appendingPathComponent("Recovery"), writePolicy: policy)
    do {
      try await LocalFileAgent(inference: engine).run(messages: [.init(role: .user, content: instruction ??
        "Use list_files and read_file to inspect \(fileName). Replace the entire contents of that existing file with exactly the lowercase word \"after\" (five letters, no newline). Call write_file with path \"\(fileName)\" and content \"after\". Read it again to verify. Do not create other files.")],
        model: model, tools: AgentFileTools(workspace: workspace)) { _ in }
      await engine.unload()
    } catch { await engine.unload(); throw error }
    let edited = try await workspace.readFile(fileName)
    XCTAssertEqual(edited, expectedContent)
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 1)
    _ = try await workspace.undo(changes)
    let restored = try await workspace.readFile(fileName)
    XCTAssertEqual(restored, initialContent)
  }
}
