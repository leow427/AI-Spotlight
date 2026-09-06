import XCTest
import AppKit
import CryptoKit
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
    let modelURL = URL(fileURLWithPath: path)
    let model = LocalModelInstallationStore().installedModels().first { $0.fileURL == modelURL }
      ?? LocalModel(id: "file-mode-smoke", displayName: "File Mode test model", fileURL: modelURL)
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

/// A measurement, separate from deterministic regression tests. Every attempt is appended before
/// assertions, including failures and its Undo result. Only generated disposable files are attached.
final class FileModeReliabilityEvaluationTests: XCTestCase {
  func testInstalledModelEvaluation() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let output = environment["AI_SPOTLIGHT_FILE_EVAL_OUTPUT"] else {
      throw XCTSkip("Opt in with AI_SPOTLIGHT_FILE_EVAL_OUTPUT (a new JSONL path).")
    }
    let model = try XCTUnwrap(LocalModelInstallationStore().installedModel())
    let limits = (environment["AI_SPOTLIGHT_FILE_EVAL_LIMITS"] ?? "1024,2048,4096").split(separator: ",").compactMap { Int($0) }
    let context = Int(environment["AI_SPOTLIGHT_FILE_EVAL_CONTEXT"] ?? "8192")!
    let repetitions = Int(environment["AI_SPOTLIGHT_FILE_EVAL_RUNS"] ?? "20")!
    let matrix = environment["AI_SPOTLIGHT_FILE_EVAL_MATRIX"] == "1"
    let heldOut = environment["AI_SPOTLIGHT_FILE_EVAL_HELD_OUT"] == "1"
    let phase = environment["AI_SPOTLIGHT_FILE_EVAL_PHASE"] ?? "unspecified"
    let url = URL(fileURLWithPath: output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: output), "Never overwrite previous attempts")
    try Data().write(to: url, options: .withoutOverwriting)
    let writer = try FileHandle(forWritingTo: url)
    defer { try? writer.close() }
    func record(_ value: CodexValue) throws {
      let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
      try writer.write(contentsOf: encoder.encode(value) + Data([10]))
      try writer.synchronize()
    }
    let modelData = try JSONEncoder().encode(model)
    try record(.object(["event": .string("configuration"), "phase": .string(phase),
      "model": try JSONDecoder().decode(CodexValue.self, from: modelData), "context": .number(Double(context)),
      "temperature": .number(0), "cache_prompt": .bool(false), "seed": .string("runtime default"),
      "runtime": .string(LocalFileRuntime.executable(for: model)?.path ?? "missing"),
      "os": .string(ProcessInfo.processInfo.operatingSystemVersionString)]))
    var failures = 0
    for limit in limits {
      let cases = heldOut ? FileEvaluationFixture.heldOut : matrix ? FileEvaluationFixture.matrix : [FileEvaluationFixture.core]
      for fixture in cases {
        for repetition in 1...repetitions {
          let identifier = "\(phase)-\(context)-\(limit)-\(fixture.name)-\(repetition)"
          try record(.object(["event": .string("attempt_started"), "id": .string(identifier),
            "task": .string(fixture.name), "prompt": .string(fixture.prompt),
            "initial_text": fixture.textStates(fixture.initial), "expected_text": fixture.textStates(fixture.expected)]))
          let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          let project = root.appendingPathComponent("Fixture")
          try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: root) }
          var originals: [String: Data] = [:]
          for (path, content) in fixture.initial {
            let data: Data
            if path.hasSuffix(".rtf") {
              let attributed = NSMutableAttributedString(string: content, attributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.blue])
              attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 21), range: NSRange(location: 0, length: 10))
              data = try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))
            } else { data = Data(content.utf8) }
            originals[path] = data
            try data.write(to: project.appendingPathComponent(path))
          }
          let trace = FileEvaluationTrace()
          let engine = LlamaServerVisionEngine(fileMaximumTokens: limit, fileContextOverride: context,
            fileDiagnostics: { await trace.diagnostic($0) })
          let workspace = try WorkspaceService(selection: .init(attachments: [.select(project)]),
            accessLevel: LocalFileCapabilities.production.access(for: model), journalDirectory: root.appendingPathComponent("Recovery"),
            writePolicy: .local(cloudAvailability: { .unavailable(reason: "Offline synthetic evaluation") },
              notice: { _ in await trace.notice() }))
          let started = ProcessInfo.processInfo.systemUptime
          var error: String?
          do {
            try await LocalFileAgent(inference: FileEvaluationInference(engine: engine, trace: trace),
              diagnostics: { await trace.event($0) }).run(
              messages: [.init(role: .user, content: fixture.prompt)], model: model,
              tools: AgentFileTools(workspace: workspace, confirmDeletion: { _ in true })) { await trace.text($0) }
          } catch let caught { error = caught.localizedDescription }
          await engine.unload()
          let seconds = ProcessInfo.processInfo.systemUptime - started
          var actual: [String: String] = [:]
          var states: [String: CodexValue] = [:]
          var formatting = true
          let names = try FileManager.default.contentsOfDirectory(atPath: project.path).sorted()
          for path in names {
            let data = try Data(contentsOf: project.appendingPathComponent(path))
            actual[path] = try WorkspaceDocument.text(path: path, data: data)
            states[path] = .object(["bytes": .number(Double(data.count)),
              "sha256": .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()),
              "text_preview": .string(String(actual[path]!.prefix(256)))])
            if path.hasSuffix(".rtf"), let original = originals[path] {
              let before = try XCTUnwrap(NSAttributedString(rtf: original, documentAttributes: nil))
              let after = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
              // Equal-length replacement; check all character attributes, not just visible text.
              formatting = formatting && before.length == after.length
              if before.length == after.length {
                for index in 0..<before.length {
                  formatting = formatting && NSDictionary(dictionary: before.attributes(at: index, effectiveRange: nil))
                    .isEqual(to: after.attributes(at: index, effectiveRange: nil))
                }
              }
            }
          }
          let changes = await workspace.changeSet()
          var undoError: String?
          do { if changes.count > 0 { _ = try await workspace.undo(changes) } }
          catch { undoError = error.localizedDescription }
          let restoredNames = try FileManager.default.contentsOfDirectory(atPath: project.path).sorted()
          var restored = restoredNames == originals.keys.sorted()
          for (path, original) in originals {
            restored = restored && (try? Data(contentsOf: project.appendingPathComponent(path))) == original
          }
          let correct = actual == fixture.expected && formatting
          let reply = await trace.output.lowercased()
          let responseCorrect = fixture.name != "ambiguous" || (changes.count == 0
            && ["occurrence", "first", "second"].contains(where: reply.contains)
            && ["which", "choose", "specif", "?"].contains(where: reply.contains))
          let success = error == nil && correct && responseCorrect && restored && undoError == nil
          if !success { failures += 1 }
          try record(.object(["event": .string("attempt_finished"), "id": .string(identifier),
            "task": .string(fixture.name), "limit": .number(Double(limit)), "context": .number(Double(context)),
            "seconds": .number(seconds), "correct": .bool(correct), "success": .bool(success),
            "response_correct": .bool(responseCorrect),
            "error": error.map(CodexValue.string) ?? .null, "formatting_preserved": .bool(formatting),
            "undo_restored": .bool(restored), "undo_error": undoError.map(CodexValue.string) ?? .null,
            "changes": .number(Double(changes.count)), "final_state": .object(states),
            "trace": await trace.value()]))
          print("FILE_EVAL \(identifier) success=\(success) correct=\(correct) undo=\(restored) seconds=\(seconds) error=\(error ?? "none")")
        }
      }
    }
    XCTAssertEqual(failures, 0, "All attempts, including failures, are retained in \(output)")
  }
}

private struct FileEvaluationFixture {
  let name: String
  let initial: [String: String]
  let expected: [String: String]
  let prompt: String
  func textStates(_ files: [String: String]) -> CodexValue {
    .object(files.mapValues { text in .object(["characters": .number(Double(text.count)),
      "utf8_bytes": .number(Double(text.utf8.count)),
      "sha256": .string(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())]) })
  }
  static let core = Self(name: "core", initial: ["fixture.txt": "before"], expected: ["fixture.txt": "after"],
    prompt: "Use list_files and read_file to inspect fixture.txt. Replace the entire contents of that existing file with exactly the lowercase word \"after\" (five letters, no newline). Call write_file with path \"fixture.txt\" and content \"after\". Read it again to verify. Do not create other files.")
  static var matrix: [Self] {
    var result: [Self] = []
    for (name, lines) in [("small", 2), ("medium", 120), ("large", 1_200)] {
      let initial = (0..<lines).map { "Note \($0): Keep this ordinary text unchanged.\n" }.joined() + "Status: before.\n"
      result.append(Self(name: "replace-\(name)", initial: ["notes.txt": initial],
        expected: ["notes.txt": initial.replacingOccurrences(of: "Status: before.", with: "Status: after.")],
        prompt: "In notes.txt change only Status: before. to Status: after. Preserve all other text exactly and verify the edit."))
    }
    result += [
      Self(name: "create", initial: [:], expected: ["new.txt": "Shopping\nMilk\nBread\n"], prompt: "Create new.txt containing exactly Shopping, Milk, and Bread on separate lines, with a final newline. Verify it."),
      Self(name: "append", initial: ["notes.txt": "Shopping\nMilk\n"], expected: ["notes.txt": "Shopping\nMilk\nBread\n"], prompt: "Append the line Bread to notes.txt exactly once, with a final newline. Keep the existing text. Verify it."),
      Self(name: "multiple-edits", initial: ["notes.txt": "Color: blue\nSize: small\nKeep: yes\n"], expected: ["notes.txt": "Color: green\nSize: large\nKeep: yes\n"], prompt: "In notes.txt change Color: blue to Color: green and Size: small to Size: large. Keep everything else, including the final newline. Verify both changes."),
      Self(name: "multi-file", initial: ["a.txt": "Status: before\n", "b.txt": "Status: before\n"], expected: ["a.txt": "Status: after\n", "b.txt": "Status: after\n"], prompt: "Change Status: before to Status: after in both a.txt and b.txt. Keep the final newlines. Verify both files."),
      Self(name: "rtf", initial: ["fixture.rtf": "Dictionary entry: before."], expected: ["fixture.rtf": "Dictionary entry: after!."], prompt: "In fixture.rtf replace only before with after! in the visible text. Preserve the surrounding text and formatting. Verify it."),
      Self(name: "protected", initial: ["fixture.swift": "let message = \"before\"\n"], expected: ["fixture.swift": "let message = \"after\"\n"], prompt: "In fixture.swift change only the string literal before to after. Keep the variable name, Swift syntax and final newline. Verify it."),
      Self(name: "ambiguous", initial: ["notes.txt": "First: before\nSecond: before\n"], expected: ["notes.txt": "First: before\nSecond: before\n"], prompt: "Change one occurrence of before to after in notes.txt. I have not decided which occurrence; ask me to choose before editing."),
      Self(name: "delete", initial: ["obsolete.txt": "Obsolete\n"], expected: [:], prompt: "Delete obsolete.txt. I confirm deletion of this disposable file. Verify it no longer exists."),
      Self(name: "move", initial: ["old.txt": "Keep me\n"], expected: ["new.txt": "Keep me\n"], prompt: "Rename old.txt to new.txt. Preserve its contents exactly. Verify the old name is gone and the new file exists.")
    ]
    return result
  }

  // Frozen after controller development; these prompts are not used to tune the implementation.
  static var heldOut: [Self] {
    let large = String(repeating: "Preserve this line in this large text document.\n", count: 40_000) + "Delivery: Tuesday\n"
    let repeated = "Done\n" + String(repeating: "Keep this entry.\n", count: 600)
    return [
      Self(name: "held-out-unicode", initial: ["travel.txt": "City: København\nCoffee: café ☕\n"],
        expected: ["travel.txt": "City: Malmö\nCoffee: café ☕\n"],
        prompt: "Update travel.txt so the city is Malmö. Leave the coffee entry and all line endings alone. Check the saved result."),
      Self(name: "held-out-near-limit", initial: ["delivery.txt": large],
        expected: ["delivery.txt": large.replacingOccurrences(of: "Delivery: Tuesday", with: "Delivery: Friday")],
        prompt: "Find the Delivery entry in delivery.txt and change Tuesday to Friday. Preserve every other character. Verify the changed entry."),
      Self(name: "held-out-append", initial: ["log.txt": repeated], expected: ["log.txt": repeated + "Done\n"],
        prompt: "Add one new line reading Done at the very end of log.txt, even though that word already appears at the beginning. Keep all existing lines and end the new line with a newline. Check the tail."),
      Self(name: "held-out-target-occurrence", initial: ["notes.txt": "First: before\nSecond: before\n"],
        expected: ["notes.txt": "First: before\nSecond: after\n"],
        prompt: "In notes.txt, change the value on the Second line to after. The First line must stay exactly as it is. Verify both lines."),
      Self(name: "held-out-rtf", initial: ["weather.rtf": "Weather note: calm."],
        expected: ["weather.rtf": "Weather note: warm."],
        prompt: "In weather.rtf, change calm to warm. Retain the punctuation and rich-text styling. Check the saved document."),
      Self(name: "held-out-quoted-punctuation", initial: ["fixture.rtf": "Dictionary entry: before."],
        expected: ["fixture.rtf": "Dictionary entry: after!."],
        prompt: "In fixture.rtf, replace the visible text \"before\" with exactly \"after!\" (six characters, including the exclamation mark). Preserve the surrounding text and formatting. Verify the saved document."),
      Self(name: "held-out-three-files", initial: ["a.txt": "Count: 10\n", "b.txt": "Count: 20\n", "c.txt": "Count: 30\n"],
        expected: ["a.txt": "Count: 11\n", "b.txt": "Count: 21\n", "c.txt": "Count: 31\n"],
        prompt: "Increase Count by one in each of a.txt, b.txt and c.txt. Keep the labels and final newlines. Check each saved file.")
    ]
  }
}

private actor FileEvaluationTrace {
  var diagnostics: [CodexValue] = []
  var events: [CodexValue] = []
  var messages: [CodexValue] = []
  var output = ""
  var notices = 0
  func diagnostic(_ value: CodexValue) { diagnostics.append(value) }
  func event(_ value: CodexValue) { events.append(value) }
  func notice() { notices += 1 }
  func text(_ value: String) { output = String((output + value).prefix(8_000)) }
  func history(_ history: [AgentInferenceMessage]) {
    messages = history.map { message in
      .object(["role": .string(message.role), "content": .string(String((message.content ?? "").prefix(2_000))),
        "calls": .array((message.toolCalls ?? []).map { call in
          .object(["name": .string(call.function.name), "arguments": .string(String(call.function.arguments.prefix(4_000))),
            "argument_bytes": .number(Double(call.function.arguments.utf8.count)),
            "valid_json": .bool((try? JSONDecoder().decode(CodexValue.self, from: Data(call.function.arguments.utf8))) != nil)])
        })])
    }
  }
  func value() -> CodexValue { .object(["inference": .array(diagnostics), "controller": .array(events), "history": .array(messages),
    "assistant_text": .string(output), "fallback_notices": .number(Double(notices))]) }
}

private struct FileEvaluationInference: LocalToolInference {
  let engine: LlamaServerVisionEngine
  let trace: FileEvaluationTrace
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    await trace.history(messages)
    return try await engine.completeTools(messages: messages, tools: tools, model: model)
  }
}
