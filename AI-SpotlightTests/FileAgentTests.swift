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

  func testUntrustedLocalModelCannotWriteEvenIfItCallsHiddenWriteTool() async throws {
    let readOnly = try WorkspaceService(selection: workspace.selection, accessLevel: .readOnly,
      journalDirectory: root.appendingPathComponent("ReadOnlyRecovery"))
    let inference = ScriptedFileInference([
      call("1", "write_file", #"{"path":"file.txt","content":"Malicious"}"#),
      AgentInferenceMessage(role: "assistant", content: "I can suggest changes. Choose Use Codex for cloud editing.")])
    try await LocalFileAgent(inference: inference).run(messages: [.init(role: .user, content: "Edit")],
      model: model, tools: AgentFileTools(workspace: readOnly)) { _ in }
    let histories = await inference.histories
    XCTAssertTrue(histories.last!.contains { $0.role == "tool" && $0.content?.contains("Read Only") == true })
    let definitions = await inference.definitions
    XCTAssertFalse(definitions.flatMap { $0 }.contains("write_file"))
    let text = try await workspace.readFile("file.txt")
    XCTAssertEqual(text, "Before")
    XCTAssertEqual(LocalFileCapabilities.production.access(for: model), .readOnly)
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
    XCTAssertEqual(start["dynamicTools"].array?.count, 9)
    let turn = try XCTUnwrap(requests.first { $0.0 == "turn/start" }?.1)
    XCTAssertEqual(turn["sandboxPolicy"]["type"].string, "workspaceWrite")
    XCTAssertEqual(turn["sandboxPolicy"]["networkAccess"].bool, false)
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
    XCTAssertEqual(payload["tools"].array?.count, 4)
    XCTAssertEqual(payload["messages"].array?.first?["content"].string, "Inspect")
    XCTAssertThrowsError(try LocalFileRuntime.response(Data(#"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"partial"}}]}"#.utf8)))
    let parsed = try LocalFileRuntime.response(Data(#"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"file.txt\"}"}}]}}]}"#.utf8))
    XCTAssertEqual(parsed.toolCalls?.first?.function.name, "read_file")
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
}

private actor ScriptedFileInference: LocalToolInference {
  var responses: [AgentInferenceMessage]
  private(set) var histories: [[AgentInferenceMessage]] = []
  private(set) var definitions: [[String]] = []
  init(_ responses: [AgentInferenceMessage]) { self.responses = responses }
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    histories.append(messages)
    definitions.append(tools.map(\.name))
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
