import Foundation

typealias CodexServerRequestHandler = @Sendable (String, CodexValue) async -> CodexValue

/// Uses the native app-server DynamicToolSpec / item/tool/call contract. Disabling environment
/// access excludes direct apply_patch and exec tools, so no write can bypass the shared journal.
enum CodexFileMode {
  static func threadParameters(model: String, selection: WorkspaceSelection) -> CodexValue {
    .object([
      "model": .string(model), "modelProvider": .string("openai"), "ephemeral": .bool(true),
      "cwd": .string(selection.cwd.path), "sandbox": .string("workspace-write"),
      "approvalPolicy": .string("untrusted"), "approvalsReviewer": .string("user"),
      "environments": .array([]),
      "runtimeWorkspaceRoots": .array(selection.attachments.filter(\.isDirectory).map { .string($0.url.path) }),
      "dynamicTools": .array(AgentFileTools.definitions(access: .readWrite).map(\.codex)),
      "baseInstructions": .string("You are AI Spotlight, a helpful assistant for file analysis and editing."),
      "developerInstructions": .string(AgentFileTools.instructions + "\nAccess: Read & Edit\n" + selection.context),
      "config": .object(["project_doc_max_bytes": .number(0), "features.skip_host_skill_discovery": .bool(true),
        "features.shell_tool": .bool(false), "features.unified_exec": .bool(false),
        "features.workspace_dependencies": .bool(false), "features.code_mode": .bool(false),
        "features.code_mode_host": .bool(true), "features.artifact": .bool(false), "features.memories": .bool(false)]),
    ])
  }

  static func sandboxPolicy(selection: WorkspaceSelection) -> CodexValue {
    // Single-file attachments never grant their parent to a model. The directory cwd is only
    // thread metadata: environments=[] leaves all file access with AgentFileTools.
    // Do not send the retired workspaceWrite.readOnlyAccess field. Read restrictions
    // are enforced by WorkspaceAccess, independently of native sandbox schema versions.
    .object(["type": .string("workspaceWrite"),
      "writableRoots": .array(selection.attachments.map { .string($0.url.path) }),
      "networkAccess": .bool(false), "excludeSlashTmp": .bool(true), "excludeTmpdirEnvVar": .bool(true)])
  }

  static func handle(method: String, params: CodexValue, tools: AgentFileTools) async -> CodexValue {
    switch method {
    case "item/tool/call":
      guard params["namespace"] == .null,
            let name = params["tool"].string, params["turnId"].string?.isEmpty == false,
            params["callId"].string?.isEmpty == false else {
        return AgentToolResult(text: "Invalid File Mode tool call.", success: false).codex
      }
      return await tools.execute(name: name, arguments: params["arguments"]).codex
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
      // Never approve direct execution or unjournaled native edits, including outside-root grants.
      return .object(["decision": .string("decline")])
    case "item/permissions/requestApproval":
      return .object(["permissions": .object([:]), "scope": .string("turn")])
    case "item/tool/requestUserInput":
      return .object(["answers": .object([:])])
    default:
      return AgentToolResult(text: "Only the attached workspace file tools are available.", success: false).codex
    }
  }
}

/// Runtime contract verification prevents older app servers from silently ignoring environments=[]
/// and exposing built-in filesystem tools. No model generation or credentials are used in this probe.
enum CodexFileModeSupport {
  static func validateSchema(at directory: URL) throws {
    let thread = directory.appendingPathComponent("v2/ThreadStartParams.json")
    // Server-initiated requests are emitted at the schema root by current CLIs.
    // Older bundles can place them under v2; validate the contract in either layout.
    let call = ["DynamicToolCallParams.json", "v2/DynamicToolCallParams.json"]
      .map { directory.appendingPathComponent($0) }
      .first { FileManager.default.fileExists(atPath: $0.path) }
    let callSchema = try call.map { try JSONDecoder().decode(CodexValue.self, from: Data(contentsOf: $0)) }
    let required = Set(callSchema?["required"].array?.compactMap(\.string) ?? [])
    let schema = try JSONDecoder().decode(CodexValue.self, from: Data(contentsOf: thread))
    guard schema["properties"]["environments"]["description"].string?.contains("Empty disables environment access") == true,
          schema["properties"]["dynamicTools"] != .null,
          schema["definitions"]["DynamicToolSpec"] != .null,
          Set(["arguments", "callId", "threadId", "tool", "turnId"]).isSubset(of: required),
          ["callId", "threadId", "tool", "turnId"].allSatisfy({ callSchema?["properties"][$0]["type"].string == "string" }) else {
      throw FileModeError.operation("This Codex version does not expose the isolated file tools AI Spotlight needs. Ordinary chat is still available.")
    }
  }
}
