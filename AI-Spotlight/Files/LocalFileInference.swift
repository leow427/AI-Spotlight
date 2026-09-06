import Foundation

enum LocalFileRuntime {
  static func executable(for model: LocalModel, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
    let candidates = [model.visionConfiguration?.serverExecutableURL.path, LocalFileRuntimeSetup.executable.path,
      environment["AI_SPOTLIGHT_LLAMA_SERVER_PATH"], "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
      .compactMap { $0 }
      + LocalModelInstallationStore().installedModels().compactMap { $0.visionConfiguration?.serverExecutableURL.path }
    return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
  }

  static func textArguments(model: LocalModel, port: UInt16, key: String, alias: String) throws -> [String] {
    guard model.fileURL.isFileURL, model.fileURL.pathExtension.lowercased() == "gguf",
          FileManager.default.isReadableFile(atPath: model.fileURL.path), executable(for: model) != nil else {
      throw FileModeError.operation("Local File Mode needs llama-server. Open Settings → Local Models → Install Local File Tools, or choose a recommended model with its included runtime. Your files stay on this Mac.")
    }
    return ["-m", model.fileURL.path, "--host", "127.0.0.1", "--port", String(port), "--api-key", key,
      "--alias", alias, "--ctx-size", String(contextWindow(for: model)), "--parallel", "1", "--offline",
      "--no-webui", "--jinja", "--no-context-shift", "--cache-ram", "0", "--reasoning-budget", "0", "--fit", "off"]
  }

  static func contextWindow(for model: LocalModel) -> Int {
    model.visionConfiguration?.contextWindow ?? max(4_096, min(16_384, model.catalogDescriptor?.recommendedContextSize ?? 8_192))
  }

  static func payload(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], alias: String) throws -> CodexValue {
    let encoded = try JSONEncoder().encode(messages)
    return .object(["model": .string(alias), "messages": try JSONDecoder().decode(CodexValue.self, from: encoded),
      "tools": .array(tools.map(\.llama)), "tool_choice": .string("auto"), "parallel_tool_calls": .bool(false),
      "stream": .bool(false), "max_tokens": .number(1_024), "temperature": .number(0.2), "cache_prompt": .bool(false)])
  }

  static func response(_ data: Data) throws -> AgentInferenceMessage {
    let value = try JSONDecoder().decode(CodexValue.self, from: data)
    guard let choice = value["choices"].array?.first,
          ["stop", "tool_calls"].contains(choice["finish_reason"].string ?? "") else {
      throw FileModeError.operation("The local model’s file response was incomplete. Try a smaller request; any completed edits are available in Review.")
    }
    let message = try JSONDecoder().decode(AgentInferenceMessage.self, from: JSONEncoder().encode(choice["message"]))
    guard message.role == "assistant",
          !(message.content ?? "").isEmpty || !(message.toolCalls ?? []).isEmpty else { throw FileModeError.invalidArguments }
    return message
  }
}
