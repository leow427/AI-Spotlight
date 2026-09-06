import XCTest
@testable import PrimaryAgent

final class FileAgentTests: XCTestCase {
  private var root: URL!
  private var workspace: WorkspaceService!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("Before".utf8).write(to: project.appendingPathComponent("file.txt"))
    workspace = try WorkspaceService(selection: WorkspaceSelection(attachments: [.select(project)]),
      accessLevel: .readWrite, journalDirectory: root.appendingPathComponent("Recovery"))
  }
  override func tearDownWithError() throws {
    workspace = nil
    try FileManager.default.removeItem(at: root)
  }

  private var model: LocalModel { LocalModel(id: "fixture", displayName: "Fixture", fileURL: root.appendingPathComponent("model.gguf")) }
  private func call(_ id: String, _ name: String, _ arguments: String) -> AgentInferenceMessage {
    AgentInferenceMessage(role: "assistant", content: nil,
      toolCalls: [AgentToolCall(id: id, function: .init(name: name, arguments: arguments))])
  }

  func testLocalStructuredLoopReadsThenEditsThroughSharedTools() async throws {
    let inference = ScriptedFileInference([
      call("1", "list_files", "{}"), call("2", "read_file", #"{"path":"file.txt"}"#),
      call("3", "apply_patch", #"{"path":"file.txt","old_text":"Before","new_text":"After"}"#),
      AgentInferenceMessage(role: "assistant", content: "Updated the file.")])
    try await LocalFileAgent(inference: inference).run(messages: [.init(role: .user, content: "Update the file")],
      model: model, tools: AgentFileTools(workspace: workspace)) { _ in }
    let text = try await workspace.readFile("file.txt")
    XCTAssertEqual(text, "After")
    let histories = await inference.histories
    XCTAssertEqual(histories.count, 4)
    XCTAssertTrue(histories[2].contains { $0.role == "tool" && $0.content?.contains("Before") == true })
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 1)
    _ = try await workspace.undo(changes)
    let restored = try await workspace.readFile("file.txt")
    XCTAssertEqual(restored, "Before")
  }

  func testToolIDsCanRepeatAcrossLocalCompletionsWithoutBreakingHistory() async throws {
    let inference = ScriptedFileInference([
      call("0", "read_file", #"{"path":"file.txt"}"#),
      call("0", "apply_patch", #"{"path":"file.txt","old_text":"Before","new_text":"After"}"#),
      AgentInferenceMessage(role: "assistant", content: "Done")])
    try await LocalFileAgent(inference: inference).run(messages: [], model: model,
      tools: AgentFileTools(workspace: workspace)) { _ in }
    let histories = await inference.histories
    let history = try XCTUnwrap(histories.last)
    let ids = history.compactMap(\.toolCalls).flatMap { $0 }.map(\.id)
    XCTAssertEqual(Set(ids).count, 2)
    XCTAssertEqual(history.compactMap(\.toolCallID), ids)
    XCTAssertTrue(ids.allSatisfy { $0.count == 9 })
    let text = try await workspace.readFile("file.txt")
    XCTAssertEqual(text, "After")
  }

  func testDuplicateIDsWithinOneResponseFailBeforeAnyMutation() async throws {
    let first = call("0", "write_file", #"{"path":"file.txt","content":"Wrong"}"#)
    let inference = ScriptedFileInference([AgentInferenceMessage(role: "assistant", content: nil,
      toolCalls: first.toolCalls! + first.toolCalls!)])
    do {
      try await LocalFileAgent(inference: inference).run(messages: [], model: model,
        tools: AgentFileTools(workspace: workspace)) { _ in }
      XCTFail("An ambiguous tool batch must fail")
    } catch { }
    let text = try await workspace.readFile("file.txt")
    XCTAssertEqual(text, "Before")
  }

  func testExplicitReadOnlyGrantRejectsHiddenWriteTool() async throws {
    let readOnly = try WorkspaceService(selection: workspace.selection, accessLevel: .readOnly,
      journalDirectory: root.appendingPathComponent("ReadOnlyRecovery"))
    let inference = ScriptedFileInference([
      call("1", "write_file", #"{"path":"file.txt","content":"Malicious"}"#),
      AgentInferenceMessage(role: "assistant", content: "This workspace grant is read-only. I can suggest changes.")])
    try await LocalFileAgent(inference: inference).run(messages: [.init(role: .user, content: "Edit")],
      model: model, tools: AgentFileTools(workspace: readOnly)) { _ in }
    let histories = await inference.histories
    XCTAssertTrue(histories.last!.contains { $0.role == "tool" && $0.content?.contains("Read Only") == true })
    let definitions = await inference.definitions
    XCTAssertFalse(definitions.flatMap { $0 }.contains("write_file"))
    let text = try await workspace.readFile("file.txt")
    XCTAssertEqual(text, "Before")
  }

  func testProductionLocalAccessIncludesAllFileToolsForImportedModels() {
    XCTAssertNil(model.catalogDescriptor)
    let access = LocalFileCapabilities.production.access(for: model)
    XCTAssertEqual(access, .readWrite)
    XCTAssertEqual(Set(AgentFileTools.definitions(access: access).map(\.name)),
      Set(["list_files", "read_file", "search_files", "get_file_metadata", "apply_patch", "write_file", "append_file", "create_file", "move_file", "delete_file"]))
  }

  func testAssistantTextWithJSONNeverExecutesAFileOperation() async throws {
    let inference = ScriptedFileInference([AgentInferenceMessage(role: "assistant", content:
      #"{"name":"delete_file","arguments":{"path":"file.txt"}}"#)])
    try await LocalFileAgent(inference: inference).run(messages: [], model: model,
      tools: AgentFileTools(workspace: workspace)) { _ in }
    let text = try await workspace.readFile("file.txt")
    XCTAssertEqual(text, "Before")
  }

  func testDeletionRequiresHostConfirmation() async throws {
    let denied = await AgentFileTools(workspace: workspace).execute(name: "delete_file", arguments: .object(["path": .string("file.txt")]))
    XCTAssertFalse(denied.success)
    let accepted = await AgentFileTools(workspace: workspace, confirmDeletion: { _ in true })
      .execute(name: "delete_file", arguments: .object(["path": .string("file.txt")]))
    XCTAssertTrue(accepted.success)
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.changes.first?.kind, "Deleted")
    _ = try await workspace.undo(changes)
  }

  func testCloudNativeToolCallWritesAndRetainsAuthenticationAndStreaming() async throws {
    let transport = FileCodexTransport()
    let client = CodexSubscriptionClient(transport: transport)
    let request = ChatRequest(sessionID: UUID(), messages: [.init(role: .user, content: "Update file.txt")],
      route: Route(mode: .cloud, providerID: CloudProviderID.chatGPT.rawValue, modelID: "test-model", usesNetwork: true))
    var text = ""
    for try await event in client.stream(request, fileTools: AgentFileTools(workspace: workspace)) {
      if case .token(let token) = event { text += token }
    }
    XCTAssertEqual(text, "Updated.")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Project/file.txt"), encoding: .utf8), "Cloud edit")
    let requests = await transport.requests
    XCTAssertTrue(requests.contains { $0.0 == "account/read" })
    let start = try XCTUnwrap(requests.first { $0.0 == "thread/start" }?.1)
    XCTAssertEqual(start["sandbox"].string, "workspace-write")
    XCTAssertEqual(start["cwd"].string, workspace.selection.cwd.path)
    XCTAssertEqual(start["environments"].array, [])
    XCTAssertEqual(start["dynamicTools"].array?.count, 10)
    let turn = try XCTUnwrap(requests.first { $0.0 == "turn/start" }?.1)
    XCTAssertEqual(turn["sandboxPolicy"]["type"].string, "workspaceWrite")
    XCTAssertEqual(turn["sandboxPolicy"]["networkAccess"].bool, false)
    XCTAssertEqual(turn["sandboxPolicy"]["readOnlyAccess"], .null)
    XCTAssertEqual(turn["sandboxPolicy"]["excludeSlashTmp"].bool, true)
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 1)
    _ = try await workspace.undo(changes)
  }

  func testCodexNeverApprovesShellOrExtraPermissions() async throws {
    let tools = AgentFileTools(workspace: workspace)
    for method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] {
      let result = await CodexFileMode.handle(method: method, params: .object(["grantRoot": .string("/")]), tools: tools)
      XCTAssertEqual(result["decision"].string, "decline")
    }
    let result = await CodexFileMode.handle(method: "item/permissions/requestApproval",
      params: .object(["permissions": .object(["network": .bool(true)])]), tools: tools)
    XCTAssertEqual(result["permissions"], .object([:]))
    let escape = await CodexFileMode.handle(method: "item/tool/call", params: .object([
      "tool": .string("write_file"), "turnId": .string("turn"), "callId": .string("call"),
      "arguments": .object(["path": .string("../escape.txt"), "content": .string("bad")])]), tools: tools)
    XCTAssertEqual(escape["success"].bool, false)
  }

  func testOrdinaryChatHasNoFileToolsOrWritableSandbox() throws {
    let parameters = CodexSubscriptionClient.threadParameters(model: "test")
    XCTAssertEqual(parameters["sandbox"].string, "read-only")
    XCTAssertEqual(parameters["dynamicTools"], .null)
    XCTAssertEqual(parameters["cwd"], .null)
    let request = ChatRequest(sessionID: UUID(), messages: [.init(role: .user, content: "Hello")],
      route: .init(mode: .cloud, providerID: CloudProviderID.chatGPT.rawValue, modelID: "test", usesNetwork: true))
    XCTAssertEqual(try CodexSubscriptionClient.turnParameters(threadID: "t", request: request)["sandboxPolicy"], .null)
  }

  func testStructuredLlamaPayloadAndTruncatedResponseRejection() throws {
    let payload = try LocalFileRuntime.payload(messages: [.init(role: "user", content: "Inspect")],
      tools: AgentFileTools.definitions(access: .readOnly), alias: "test")
    XCTAssertEqual(payload["parallel_tool_calls"].bool, false)
    XCTAssertEqual(payload["temperature"], .number(0))
    XCTAssertEqual(payload["tools"].array?.count, 4)
    XCTAssertEqual(payload["messages"].array?.first?["content"].string, "Inspect")
    XCTAssertThrowsError(try LocalFileRuntime.response(Data(#"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"partial"}}]}"#.utf8)))
    let parsed = try LocalFileRuntime.response(Data(#"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"file.txt\"}"}}]}}]}"#.utf8))
    XCTAssertEqual(parsed.toolCalls?.first?.function.name, "read_file")
  }

  func testCloudEditingAvailabilityChecksMetadataWithoutStartingAModelTurn() async {
    let transport = FileAvailabilityTransport(models: ["configured-codex"])
    let availability = await CodexSubscriptionClient(transport: transport).fileEditingAvailability(preferredModelID: "configured-codex")
    XCTAssertEqual(availability, .available(modelID: "configured-codex"))
    let methods = await transport.methods
    XCTAssertEqual(Set(methods), ["account/read", "model/list"])
  }

  func testLocalFallbackRetainsTheUnderlyingCodexError() async {
    let transport = FileAvailabilityTransport(supportsFiles: false)
    let availability = await CodexSubscriptionClient(transport: transport).fileEditingAvailability(preferredModelID: "codex")
    XCTAssertEqual(availability, .unavailable(reason: FileModeError.inactive.localizedDescription))
  }

  func testMissingAccountUnsupportedRuntimeAndNoModelsAllowLocalFallback() async {
    for transport in [FileAvailabilityTransport(hasAccount: false), FileAvailabilityTransport(supportsFiles: false),
      FileAvailabilityTransport(models: [])] {
      let availability = await CodexSubscriptionClient(transport: transport).fileEditingAvailability(preferredModelID: "configured-codex")
      guard case .unavailable = availability else { XCTFail("Should allow local fallback"); continue }
      let methods = await transport.methods
      XCTAssertFalse(methods.contains("thread/start"))
      XCTAssertFalse(methods.contains("turn/start"))
    }
  }

  func testToolSchemaRejectsUnknownToolsAndWrongArgumentTypes() async {
    let tools = AgentFileTools(workspace: workspace)
    for (name, args) in [("run_command", CodexValue.object([:])),
      ("read_file", .object(["path": .string("file.txt"), "offset": .number(-1)])),
      ("write_file", .object(["path": .string("file.txt"), "content": .bool(true)])),
      ("list_files", .object(["cwd": .string("/")]))] {
      let result = await tools.execute(name: name, arguments: args)
      XCTAssertFalse(result.success)
    }
  }

  func testMalformedArgumentsCanRecoverWithoutExecutingPartialJSON() async throws {
    let inference = ScriptedFileInference([
      call("1", "write_file", #"{"path":"file.txt","content":"BROKEN""#),
      call("read", "read_file", #"{"path":"file.txt"}"#),
      call("2", "apply_patch", #"{"path":"file.txt","old_text":"Before","new_text":"After"}"#),
      .init(role: "assistant", content: "Done")])
    try await LocalFileAgent(inference: inference).run(messages: [], model: model,
      tools: AgentFileTools(workspace: workspace)) { _ in }
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 1)
    XCTAssertEqual(changes.changes.first?.before.data, Data("Before".utf8))
    XCTAssertEqual(changes.changes.first?.after.data, Data("After".utf8))
    _ = try await workspace.undo(changes)
    let restored = try await workspace.readFile("file.txt")
    XCTAssertEqual(restored, "Before")
  }

  func testRuntimeFailureAfterSuccessfulOperationKeepsExactUndo() async throws {
    let inference = FailingFileInference(first: call("1", "write_file", #"{"path":"file.txt","content":"After"}"#))
    do {
      try await LocalFileAgent(inference: inference).run(messages: [], model: model,
        tools: AgentFileTools(workspace: workspace)) { _ in }
      XCTFail("Runtime failure must remain visible")
    } catch { XCTAssertEqual(error as? FileModeError, .operation("Injected runtime failure")) }
    let edited = try await workspace.readFile("file.txt")
    XCTAssertEqual(edited, "After")
    let saved = await workspace.changeSet()
    _ = try await workspace.undo(saved)
    let restored = try await workspace.readFile("file.txt")
    XCTAssertEqual(restored, "Before")
  }

  func testCancellationAfterInferenceRejectsReturnedMutation() async throws {
    let inference = CancellingFileInference(response: call("1", "write_file", #"{"path":"file.txt","content":"After"}"#))
    let localModel = model
    let localWorkspace = workspace!
    let task = Task {
      try await LocalFileAgent(inference: inference).run(messages: [], model: localModel,
        tools: AgentFileTools(workspace: localWorkspace)) { _ in }
    }
    do { try await task.value; XCTFail("Cancelled response must not execute") }
    catch { XCTAssertTrue(error is CancellationError) }
    let original = try await workspace.readFile("file.txt")
    let changes = await workspace.changeSet()
    XCTAssertEqual(original, "Before")
    XCTAssertEqual(changes.count, 0)
  }

  func testBatchedEditWaitsUntilModelHasSeenReadResult() async throws {
    var batch = call("1", "read_file", #"{"path":"file.txt"}"#)
    batch.toolCalls! += call("2", "write_file", #"{"path":"file.txt","content":"Guessed before reading"}"#).toolCalls!
    let inference = ScriptedFileInference([batch,
      call("3", "apply_patch", #"{"path":"file.txt","old_text":"Before","new_text":"After"}"#),
      .init(role: "assistant", content: "Done")])
    try await LocalFileAgent(inference: inference).run(messages: [], model: model,
      tools: AgentFileTools(workspace: workspace)) { _ in }
    let histories = await inference.histories
    XCTAssertEqual(histories[1].filter { $0.role == "assistant" }.last?.toolCalls?.count, 1)
    XCTAssertFalse(histories[1].contains { $0.toolCalls?.contains { $0.function.name == "write_file" } == true })
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.changes.first?.before.data, Data("Before".utf8))
    XCTAssertEqual(changes.changes.first?.after.data, Data("After".utf8))
  }

  func testCancellationKeepsEarlierSuccessfulEditAndRejectsLaterMutation() async throws {
    let inference = RecoveringFileInference(responses: [
      .success(call("1", "write_file", #"{"path":"file.txt","content":"After"}"#)),
      .success(call("2", "append_file", #"{"path":"file.txt","content":" must not appear"}"#))],
      onCall: { count in if count == 2 { withUnsafeCurrentTask { $0?.cancel() } } })
    let localModel = model
    let localWorkspace = workspace!
    let task = Task {
      try await LocalFileAgent(inference: inference).run(messages: [], model: localModel,
        tools: AgentFileTools(workspace: localWorkspace)) { _ in XCTFail("Do not emit completion after cancellation") }
    }
    do { try await task.value; XCTFail("Cancellation must remain visible") }
    catch { XCTAssertTrue(error is CancellationError) }
    let file = root.appendingPathComponent("Project/file.txt")
    XCTAssertEqual(try Data(contentsOf: file), Data("After".utf8))
    _ = try await workspace.undo(workspace.changeSet())
    XCTAssertEqual(try Data(contentsOf: file), Data("Before".utf8))
  }

  func testDuplicateAppendIsNotReplayedAcrossDifferentIDsAndJSONOrdering() async throws {
    let inference = ScriptedFileInference([
      call("read", "read_file", #"{"path":"file.txt"}"#),
      call("1", "apply_patch", #"{"path":"file.txt","old_text":"Before","new_text":"Before\nAdded"}"#),
      call("2", "apply_patch", #"{ "new_text": "Before\nAdded", "old_text": "Before", "path": "file.txt" }"#),
      .init(role: "assistant", content: "Done")])
    try await LocalFileAgent(inference: inference).run(messages: [], model: model,
      tools: AgentFileTools(workspace: workspace)) { _ in }
    let edited = try await workspace.readFile("file.txt")
    XCTAssertEqual(edited, "Before\nAdded")
    let history = await inference.histories.last!
    XCTAssertTrue(history.contains { $0.role == "tool" && $0.content?.contains("not repeated") == true })
    _ = try await workspace.undo(workspace.changeSet())
    let restored = try await workspace.readFile("file.txt")
    XCTAssertEqual(restored, "Before")
  }

  func testRepeatedUnchangedReadsStopWithBoundedFailure() async throws {
    let inference = ScriptedFileInference((1...4).map { call(String($0), "read_file", #"{"path":"file.txt"}"#) })
    do {
      try await LocalFileAgent(inference: inference).run(messages: [], model: model,
        tools: AgentFileTools(workspace: workspace)) { _ in }
      XCTFail("Unproductive reads must stop")
    } catch { XCTAssertTrue(error.localizedDescription.contains("without progress")) }
    let histories = await inference.histories
    XCTAssertEqual(histories.count, 3)
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 0)
  }

  func testIncompleteRecoveryNeverReplaysEarlierAppend() async throws {
    let append = call("1", "apply_patch", #"{"path":"file.txt","old_text":"Before","new_text":"Before\nAdded"}"#)
    let inference = RecoveringFileInference(responses: [.success(call("read", "read_file", #"{"path":"file.txt"}"#)), .success(append), .failure(.incompleteResponse),
      .success(append), .success(.init(role: "assistant", content: "Done"))])
    try await LocalFileAgent(inference: inference).run(messages: [], model: model,
      tools: AgentFileTools(workspace: workspace)) { _ in }
    let edited = try await workspace.readFile("file.txt")
    XCTAssertEqual(edited, "Before\nAdded")
    let histories = await inference.histories
    XCTAssertTrue(histories[3].contains { $0.content?.contains("NONE of its calls") == true })
    _ = try await workspace.undo(workspace.changeSet())
    let restored = try await workspace.readFile("file.txt")
    XCTAssertEqual(restored, "Before")
  }

  func testIncompleteRecoveryHasATotalBoundAndLeavesNoChanges() async throws {
    let inference = RecoveringFileInference(responses: Array(repeating: .failure(.incompleteResponse), count: 4))
    do {
      try await LocalFileAgent(inference: inference).run(messages: [], model: model,
        tools: AgentFileTools(workspace: workspace)) { _ in }
      XCTFail("Recovery must stop")
    } catch { XCTAssertTrue(error.localizedDescription.contains("recovery attempts")) }
    let histories = await inference.histories
    XCTAssertEqual(histories.count, 3)
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 0)
  }

  func testConcurrentUserEditDuringRecoveryIsNeverOverwrittenOrAcknowledgedAsCachedSuccess() async throws {
    let file = root.appendingPathComponent("Project/file.txt")
    let append = call("1", "apply_patch", #"{"path":"file.txt","old_text":"Before","new_text":"Before\nAdded"}"#)
    let inference = RecoveringFileInference(responses: [.success(call("read", "read_file", #"{"path":"file.txt"}"#)), .success(append), .failure(.incompleteResponse), .success(append)],
      onCall: { count in if count == 3 { try Data("user changed this".utf8).write(to: file) } })
    do {
      try await LocalFileAgent(inference: inference).run(messages: [], model: model,
        tools: AgentFileTools(workspace: workspace)) { _ in XCTFail("Do not report cached success") }
      XCTFail("A concurrent edit must stop recovery")
    } catch { XCTAssertEqual(error as? FileModeError, .conflict) }
    let changes = await workspace.changeSet()
    do { _ = try await workspace.undo(changes); XCTFail("Do not roll back the user's edit") }
    catch { XCTAssertEqual(error as? FileModeError, .conflict) }
    XCTAssertEqual(try Data(contentsOf: file), Data("user changed this".utf8))
    XCTAssertEqual(changes.changes.first?.before.data, Data("Before".utf8))
  }

  func testFailedEditCannotBeReportedAsSuccessfulCompletion() async throws {
    let inference = ScriptedFileInference([
      call("1", "apply_patch", #"{"path":"file.txt","old_text":"Missing","new_text":"After"}"#),
      .init(role: "assistant", content: "Successfully edited."),
      .init(role: "assistant", content: "Successfully edited."),
      .init(role: "assistant", content: "Successfully edited.")])
    do {
      try await LocalFileAgent(inference: inference).run(messages: [], model: model,
        tools: AgentFileTools(workspace: workspace)) { _ in XCTFail("Do not emit unverified success") }
      XCTFail("Unresolved edit failure must remain visible")
    } catch { XCTAssertTrue(error.localizedDescription.contains("failed edit")) }
    let original = try await workspace.readFile("file.txt")
    XCTAssertEqual(original, "Before")
  }

  func testContextAccountingReservesTheEntireConfiguredResponseBudget() throws {
    for limit in [1_024, 2_048, 4_096] {
      try LocalFileRuntime.validateBudget(promptTokens: 8_192 - limit - 65, maximumTokens: limit, contextWindow: 8_192)
      XCTAssertThrowsError(try LocalFileRuntime.validateBudget(promptTokens: 8_192 - limit - 64, maximumTokens: limit, contextWindow: 8_192)) {
        XCTAssertEqual($0 as? FileModeError, .contextExhausted)
      }
      let payload = try LocalFileRuntime.payload(messages: [], tools: [], alias: "test", maximumTokens: limit)
      XCTAssertEqual(payload["max_tokens"].integer, limit)
    }
    XCTAssertThrowsError(try LocalFileRuntime.validateBudget(promptTokens: 0, maximumTokens: 4_096, contextWindow: 4_096))
    XCTAssertThrowsError(try LocalFileRuntime.validateBudget(promptTokens: Int.max, maximumTokens: 1_024, contextWindow: 8_192))
  }

  func testAppendReceiptShowsTheTailEvenWhenTextAlreadyOccursEarlier() async throws {
    let original = "Added\n" + String(repeating: "Keep this line.\n", count: 200)
    try Data(original.utf8).write(to: root.appendingPathComponent("Project/file.txt"))
    let result = await AgentFileTools(workspace: workspace).execute(name: "append_file",
      arguments: .object(["path": .string("file.txt"), "content": .string("Added\n")]))
    XCTAssertTrue(result.success, result.text)
    let receipt = try JSONDecoder().decode(CodexValue.self, from: Data(result.text.utf8))
    XCTAssertEqual(receipt["read_back"]["text"].string, String((original + "Added\n").suffix(500)))
    XCTAssertEqual(receipt["read_back"]["has_more"].bool, false)
    _ = try await workspace.undo(workspace.changeSet())
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Project/file.txt"), encoding: .utf8), original)
  }

  func testMissingReadPathReportsARecoverablePathErrorWithoutWeakeningLinkChecks() async throws {
    let tools = AgentFileTools(workspace: workspace)
    let missing = await tools.execute(name: "read_file", arguments: .object(["path": .string("absent.txt")]))
    XCTAssertFalse(missing.success)
    XCTAssertFalse(missing.terminal)
    XCTAssertTrue(missing.text.contains("does not exist"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Project/link.txt"),
      withDestinationURL: root.appendingPathComponent("Project/file.txt"))
    let link = await tools.execute(name: "read_file", arguments: .object(["path": .string("link.txt")]))
    XCTAssertFalse(link.success)
    XCTAssertTrue(link.terminal)
    XCTAssertTrue(link.text.contains("links"))
    let original = try await workspace.readFile("file.txt")
    XCTAssertEqual(original, "Before")
  }

  func testMutationReceiptReadsBackActualContents() async throws {
    let result = await AgentFileTools(workspace: workspace).execute(name: "write_file",
      arguments: .object(["path": .string("file.txt"), "content": .string("After")]))
    XCTAssertTrue(result.success)
    let receipt = try JSONDecoder().decode(CodexValue.self, from: Data(result.text.utf8))
    XCTAssertEqual(receipt["path"].string, "file.txt")
    XCTAssertEqual(receipt["verified"].bool, true)
    XCTAssertEqual(receipt["read_back"]["text"].string, "After")
    let actual = try await workspace.readFile("file.txt")
    XCTAssertEqual(actual, receipt["read_back"]["text"].string)
  }

  func testReceiptFailsIfAnotherWriterChangesTheFileAfterMutation() async throws {
    let file = root.appendingPathComponent("Project/file.txt")
    let racing = try WorkspaceService(selection: workspace.selection, accessLevel: .readWrite,
      journalDirectory: root.appendingPathComponent("RacingRecovery"),
      failureAfterWrite: { _ in try Data("newer user text".utf8).write(to: file) })
    let result = await AgentFileTools(workspace: racing).execute(name: "write_file",
      arguments: .object(["path": .string("file.txt"), "content": .string("After")]))
    XCTAssertFalse(result.success)
    XCTAssertTrue(result.terminal)
    XCTAssertEqual(try Data(contentsOf: file), Data("newer user text".utf8))
    let changes = await racing.changeSet()
    XCTAssertEqual(changes.changes.first?.before.data, Data("Before".utf8))
    do { _ = try await racing.undo(changes); XCTFail("Keep the newer user text") }
    catch { XCTAssertEqual(error as? FileModeError, .conflict) }
  }

  func testLaterRuntimeFailureKeepsUndoForModifiedCreatedDeletedAndMovedFiles() async throws {
    let deleted = root.appendingPathComponent("Project/deleted.txt")
    try Data("Restore me".utf8).write(to: deleted)
    let inference = RecoveringFileInference(responses: [
      .success(call("1", "write_file", #"{"path":"file.txt","content":"After"}"#)),
      .success(call("2", "create_file", #"{"path":"created.txt","content":"New"}"#)),
      .success(call("3", "move_file", #"{"from":"file.txt","to":"moved.txt"}"#)),
      .success(call("4", "delete_file", #"{"path":"deleted.txt"}"#)),
      .failure(.operation("Injected runtime failure"))])
    do {
      try await LocalFileAgent(inference: inference).run(messages: [], model: model,
        tools: AgentFileTools(workspace: workspace, confirmDeletion: { _ in true })) { _ in }
      XCTFail()
    } catch { XCTAssertEqual(error as? FileModeError, .operation("Injected runtime failure")) }
    let changes = await workspace.changeSet()
    XCTAssertEqual(changes.count, 4)
    _ = try await workspace.undo(changes)
    let restored = try await workspace.readFile("file.txt")
    XCTAssertEqual(restored, "Before")
    XCTAssertEqual(try Data(contentsOf: deleted), Data("Restore me".utf8))
    let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Project").path).sorted()
    XCTAssertEqual(names, ["deleted.txt", "file.txt"])
  }

  func testDedicatedAppendIsExactDeduplicatedAndUndoable() async throws {
    let inference = ScriptedFileInference([
      call("1", "append_file", #"{"path":"file.txt","content":"\nAdded\n"}"#),
      call("2", "append_file", #"{"content":"\nAdded\n","path":"file.txt"}"#),
      .init(role: "assistant", content: "Done")])
    try await LocalFileAgent(inference: inference).run(messages: [], model: model,
      tools: AgentFileTools(workspace: workspace)) { _ in }
    let edited = try await workspace.readFile("file.txt")
    XCTAssertEqual(edited, "Before\nAdded\n")
    _ = try await workspace.undo(workspace.changeSet())
    let restored = try await workspace.readFile("file.txt")
    XCTAssertEqual(restored, "Before")
  }

  func testPrematureCompletionAfterInvalidArgumentsGetsBoundedRecovery() async throws {
    let inference = ScriptedFileInference([
      call("1", "append_file", #"{"path":"file.txt","content":42}"#),
      .init(role: "assistant", content: "Done"),
      call("2", "append_file", #"{"path":"file.txt","content":"\nAdded"}"#),
      .init(role: "assistant", content: "Done")])
    try await LocalFileAgent(inference: inference).run(messages: [], model: model,
      tools: AgentFileTools(workspace: workspace)) { _ in }
    let histories = await inference.histories
    XCTAssertTrue(histories[2].contains { $0.content?.contains("edit is unfinished") == true })
    let edited = try await workspace.readFile("file.txt")
    XCTAssertEqual(edited, "Before\nAdded")
  }
}

private actor RecoveringFileInference: LocalToolInference {
  var responses: [Result<AgentInferenceMessage, FileModeError>]
  var histories: [[AgentInferenceMessage]] = []
  let onCall: @Sendable (Int) throws -> Void
  init(responses: [Result<AgentInferenceMessage, FileModeError>], onCall: @escaping @Sendable (Int) throws -> Void = { _ in }) {
    self.responses = responses
    self.onCall = onCall
  }
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    histories.append(messages)
    try onCall(histories.count)
    guard !responses.isEmpty else { XCTFail("Unexpected extra inference"); throw FileModeError.inactive }
    return try responses.removeFirst().get()
  }
}

private actor FailingFileInference: LocalToolInference {
  var first: AgentInferenceMessage?
  init(first: AgentInferenceMessage) { self.first = first }
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    if let first { self.first = nil; return first }
    throw FileModeError.operation("Injected runtime failure")
  }
}

private struct CancellingFileInference: LocalToolInference {
  let response: AgentInferenceMessage
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    withUnsafeCurrentTask { $0?.cancel() }
    return response
  }
}

private actor ScriptedFileInference: LocalToolInference {
  var responses: [AgentInferenceMessage]
  private(set) var histories: [[AgentInferenceMessage]] = []
  private(set) var definitions: [[String]] = []
  init(_ responses: [AgentInferenceMessage]) { self.responses = responses }
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    histories.append(messages)
    definitions.append(tools.map(\.name))
    guard !responses.isEmpty else { XCTFail("Unexpected extra inference"); throw FileModeError.inactive }
    return responses.removeFirst()
  }
}

private actor FileCodexTransport: CodexRPCTransport {
  private var observer: AsyncThrowingStream<CodexNotification, Error>.Continuation?
  private var handler: CodexServerRequestHandler?
  private(set) var requests: [(String, CodexValue)] = []
  func prepareFileMode() async throws {}
  func setFileHandler(threadID: String, handler: CodexServerRequestHandler?) async throws { self.handler = handler }
  func notifications() async throws -> CodexNotificationSubscription {
    let stream = AsyncThrowingStream<CodexNotification, Error> { self.observer = $0 }
    return CodexNotificationSubscription(stream: stream, cancel: {})
  }
  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    requests.append((method, params))
    switch method {
    case "account/read": return .object(["account": .object(["type": .string("chatgpt"), "planType": .string("plus")])])
    case "thread/start": return .object(["thread": .object(["id": .string("file-thread")])])
    case "turn/start":
      let result = await handler?("item/tool/call", .object(["threadId": .string("file-thread"),
        "turnId": .string("turn"), "callId": .string("call"), "tool": .string("write_file"),
        "arguments": .object(["path": .string("file.txt"), "content": .string("Cloud edit")])]))
      guard result?["success"].bool == true else { throw FileModeError.invalidArguments }
      observer?.yield(.init(method: "item/agentMessage/delta", params: .object([
        "threadId": .string("file-thread"), "turnId": .string("turn"), "delta": .string("Updated.")])))
      observer?.yield(.init(method: "turn/completed", params: .object([
        "threadId": .string("file-thread"), "turn": .object(["id": .string("turn"), "status": .string("completed")])])))
      return .object(["turn": .object(["id": .string("turn")])])
    default: return .object([:])
    }
  }
}

private actor FileAvailabilityTransport: CodexRPCTransport {
  let hasAccount: Bool
  let supportsFiles: Bool
  let models: [String]
  private(set) var methods: [String] = []
  init(hasAccount: Bool = true, supportsFiles: Bool = true, models: [String] = ["configured-codex"]) {
    self.hasAccount = hasAccount; self.supportsFiles = supportsFiles; self.models = models
  }
  func prepareFileMode() async throws { if !supportsFiles { throw FileModeError.inactive } }
  func notifications() async throws -> CodexNotificationSubscription { throw FileModeError.inactive }
  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    methods.append(method)
    switch method {
    case "account/read": return .object(["account": hasAccount ? .object(["type": .string("chatgpt")]) : .null])
    case "model/list": return .object(["data": .array(models.map { .object(["model": .string($0), "displayName": .string($0)]) })])
    default: XCTFail("Availability must not start cloud inference"); throw FileModeError.inactive
    }
  }
}
