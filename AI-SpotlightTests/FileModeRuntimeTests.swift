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

  func testRealLocalModelEditsRichTextAndUndoes() async throws {
    try await runSmoke(fileName: "fixture.rtf", initialContent: "Dictionary entry: before.",
      expectedContent: "Dictionary entry: after.",
      instruction: "Read fixture.rtf. Use apply_patch to replace only the word before with after in the visible text. Keep the rest unchanged. Read the file again to verify. Do not create or rename files.",
      policy: .local(cloudAvailability: { .unavailable(reason: "Offline test fixture") }, notice: { _ in }))
  }

  /// Explicit opt-in sends only a disposable, synthetic RTF fixture through the real native client.
  func testRealCodexEditsRichTextAndUndoes() async throws {
    guard ProcessInfo.processInfo.environment["AI_SPOTLIGHT_CODEX_FILE_SMOKE"] == "1" else {
      throw XCTSkip("Set AI_SPOTLIGHT_CODEX_FILE_SMOKE=1 to test the signed-in Codex connection with synthetic RTF text.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("fixture.rtf")
    let original = try WorkspaceDocument.create(path: "fixture.rtf", content: "Dictionary entry: before.")
    try original.write(to: file)
    let workspace = try WorkspaceService(selection: .init(attachments: [.select(file)]), accessLevel: .readWrite,
      journalDirectory: root.appendingPathComponent("Recovery"))
    let server = CodexAppServer(configuration: .fileMode)
    let trace = FileSmokeTrace()
    let client = CodexSubscriptionClient(transport: FileSmokeCodexTransport(server: server, trace: trace), thinkingCapacity: { .low })
    let availability = await client.fileEditingAvailability(preferredModelID: CodexSubscriptionClient.defaultModelID)
    guard case .available(let modelID) = availability else {
      await server.disconnect()
      XCTFail("The signed-in Codex connection must support File Mode: \(availability)")
      return
    }
    let request = ChatRequest(sessionID: UUID(), messages: [.init(role: .user, content:
      "Read fixture.rtf. Use apply_patch to replace only the word before with after in its visible text. Keep the rest unchanged. Read again to verify. Do not create or rename files.")],
      route: .init(mode: .cloud, providerID: CloudProviderID.chatGPT.rawValue, modelID: modelID, usesNetwork: true))
    var response = ""
    do {
      for try await event in client.stream(request, fileTools: AgentFileTools(workspace: workspace)) {
        if case .token(let text) = event { response += text }
      }
      await server.disconnect()
    } catch { await server.disconnect(); throw error }
    let saved = try Data(contentsOf: file)
    let calls = await trace.entries
    XCTAssertEqual(try WorkspaceDocument.text(path: "fixture.rtf", data: saved), "Dictionary entry: after.", "Synthetic fixture response: \(response). Tools: \(calls)")
    XCTAssertTrue(saved.starts(with: Data(#"{\rtf"#.utf8)))
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 1)
    let recovery = try WorkspaceService(selection: changes.selection, accessLevel: .readWrite,
      journalDirectory: root.appendingPathComponent("Recovery"))
    _ = try await recovery.undo(changes)
    XCTAssertEqual(try Data(contentsOf: file), original)
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
    let original = try WorkspaceDocument.create(path: fileName, content: initialContent)
    try original.write(to: project.appendingPathComponent(fileName))
    let engine = LlamaServerVisionEngine()
    let trace = FileSmokeTrace()
    let model = LocalModel(id: "file-mode-smoke", displayName: "File Mode test model", fileURL: URL(fileURLWithPath: path))
    let workspace = try WorkspaceService(selection: .init(attachments: [.select(project)]),
      accessLevel: LocalFileCapabilities.production.access(for: model), journalDirectory: root.appendingPathComponent("Recovery"), writePolicy: policy)
    do {
      try await LocalFileAgent(inference: FileSmokeLocalInference(engine: engine, trace: trace)).run(messages: [.init(role: .user, content: instruction ??
        "Use list_files and read_file to inspect \(fileName). Replace the entire contents of that existing file with exactly the lowercase word \"after\" (five letters, no newline). Call write_file with path \"\(fileName)\" and content \"after\". Read it again to verify. Do not create other files.")],
        model: model, tools: AgentFileTools(workspace: workspace)) { _ in }
      await engine.unload()
    } catch { await engine.unload(); throw error }
    let edited = try await workspace.readFile(fileName)
    let calls = await trace.entries
    XCTAssertEqual(edited, expectedContent, "Synthetic fixture tools: \(calls)")
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 1)
    _ = try await workspace.undo(changes)
    let restored = try await workspace.readFile(fileName)
    XCTAssertEqual(restored, initialContent)
    XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(fileName)), original)
  }
}

private actor FileSmokeTrace {
  var entries: [String] = []
  func record(_ value: String) { entries.append(String(value.prefix(2_000))) }
}

private struct FileSmokeCodexTransport: CodexRPCTransport {
  let server: any CodexRPCTransport
  let trace: FileSmokeTrace
  func prepareFileMode() async throws { try await server.prepareFileMode() }
  func notifications() async throws -> CodexNotificationSubscription {
    let subscription = try await server.notifications()
    let stream = AsyncThrowingStream<CodexNotification, Error> { continuation in
      let task = Task {
        do {
          for try await notification in subscription.stream {
            if notification.method == "item/completed" || notification.method == "error" {
              await trace.record("Event: \(notification.method) \(notification.params)")
            }
            continuation.yield(notification)
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return CodexNotificationSubscription(stream: stream, cancel: subscription.cancel)
  }
  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    try await server.request(method, params: params)
  }
  func setFileHandler(threadID: String, handler: CodexServerRequestHandler?) async throws {
    guard let handler else { try await server.setFileHandler(threadID: threadID, handler: nil); return }
    try await server.setFileHandler(threadID: threadID) { method, params in
      let result = await handler(method, params)
      await trace.record("\(method): \(params) -> \(result)")
      return result
    }
  }
}

private struct FileSmokeLocalInference: LocalToolInference {
  let engine: LlamaServerVisionEngine
  let trace: FileSmokeTrace
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    let result = try await engine.completeTools(messages: messages, tools: tools, model: model)
    await trace.record("\(result)")
    return result
  }
}
