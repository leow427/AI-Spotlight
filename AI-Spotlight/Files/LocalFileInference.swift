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
      "--no-webui", "--jinja", "--no-context-shift", "--cache-ram", "0", "--reasoning-budget", "-1", "--fit", "off"]
  }

  static func contextWindow(for model: LocalModel) -> Int {
    model.visionConfiguration?.contextWindow ?? max(4_096, min(16_384, model.catalogDescriptor?.recommendedContextSize ?? 8_192))
  }

  static func validateBudget(promptTokens: Int, maximumTokens: Int, contextWindow: Int) throws {
    guard promptTokens >= 0, (128...4_096).contains(maximumTokens), (4_096...32_768).contains(contextWindow) else {
      throw FileModeError.invalidArguments
    }
    guard promptTokens < contextWindow - maximumTokens - 64 else { throw FileModeError.contextExhausted }
  }

  static func payload(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], alias: String,
                      maximumTokens: Int = 1_024) throws -> CodexValue {
    let encoded = try JSONEncoder().encode(messages)
    return .object(["model": .string(alias), "messages": try JSONDecoder().decode(CodexValue.self, from: encoded),
      "tools": .array(tools.map(\.llama)), "tool_choice": .string("auto"), "parallel_tool_calls": .bool(false),
      "chat_template_kwargs": .object(["enable_thinking": .bool(messages.first?.extendedThinking == true)]),
      "reasoning_budget": .number(messages.first?.extendedThinking == true ? 1_024 : 0),
      "stream": .bool(false), "max_tokens": .number(Double(maximumTokens)), "temperature": .number(0), "cache_prompt": .bool(false)])
  }

  static func response(_ data: Data) throws -> AgentInferenceMessage {
    let value = try JSONDecoder().decode(CodexValue.self, from: data)
    guard let choice = value["choices"].array?.first else { throw FileModeError.invalidArguments }
    if choice["finish_reason"].string == "length" { throw FileModeError.incompleteResponse }
    guard ["stop", "tool_calls"].contains(choice["finish_reason"].string ?? "") else {
      throw FileModeError.operation("The local runtime stopped with an unsupported finish reason. No calls from that response were executed. Review keeps earlier edits.")
    }
    let message = try JSONDecoder().decode(AgentInferenceMessage.self, from: JSONEncoder().encode(choice["message"]))
    guard message.role == "assistant",
          !(message.content ?? "").isEmpty || !(message.toolCalls ?? []).isEmpty else { throw FileModeError.invalidArguments }
    return message
  }
}
