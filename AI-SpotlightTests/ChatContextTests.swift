import Foundation
import XCTest
@testable import PrimaryAgent

final class ChatContextTests: XCTestCase {
  private let budget = ContextBudget(contextWindow: 100, outputTokens: 20, overheadTokens: 10)

  func testInputBoundaryReservesOutputAndOverhead() throws {
    for length in [69, 70] {
      let current = ChatMessage(role: .user, content: String(repeating: "x", count: length))
      let prepared = try prepare([current])
      XCTAssertEqual(prepared.messages, [current])
      XCTAssertLessThanOrEqual(prepared.inputTokenCount + budget.outputTokens + budget.overheadTokens, 100)
    }
    XCTAssertThrowsError(try prepare([ChatMessage(role: .user, content: String(repeating: "x", count: 71))])) {
      XCTAssertEqual($0 as? ChatContextError, .oversizedPrompt(inputLimit: 70))
    }
  }

  func testTrimmingRetainsWholeRecentTurnsAndCurrentMessageExactlyOnce() throws {
    let messages = [
      ChatMessage(role: .user, content: String(repeating: "old", count: 20)),
      ChatMessage(role: .assistant, content: "old answer"),
      ChatMessage(role: .user, content: "recent question"),
      ChatMessage(role: .assistant, content: "recent answer"),
      ChatMessage(role: .user, content: "latest question"),
    ]
    let original = messages
    let prepared = try prepare(messages)
    XCTAssertEqual(prepared.messages, Array(messages.suffix(3)))
    XCTAssertEqual(prepared.omittedMessageCount, 2)
    XCTAssertNotNil(prepared.notice)
    XCTAssertEqual(messages, original)
  }

  func testUnansweredAndEmptyTurnsDoNotLeaveOrphanedAssistantContext() throws {
    let current = ChatMessage(role: .user, content: "current")
    let messages = [
      ChatMessage(role: .assistant, content: "orphan"),
      ChatMessage(role: .user, content: "failed"),
      ChatMessage(role: .assistant, content: ""),
      ChatMessage(role: .user, content: "unanswered"),
      ChatMessage(role: .user, content: "answered"),
      ChatMessage(role: .assistant, content: "partial but useful"),
      current,
    ]
    let prepared = try prepare(messages)
    XCTAssertEqual(prepared.messages, Array(messages.suffix(3)))
    XCTAssertEqual(prepared.omittedMessageCount, 4)
  }

  func testOversizedRecentTurnDoesNotPullInDisconnectedOlderTurns() throws {
    let messages = [
      ChatMessage(role: .user, content: "old"),
      ChatMessage(role: .assistant, content: "old answer"),
      ChatMessage(role: .user, content: "recent"),
      ChatMessage(role: .assistant, content: String(repeating: "x", count: 80)),
      ChatMessage(role: .user, content: "current"),
    ]
    XCTAssertEqual(try prepare(messages).messages, Array(messages.suffix(1)))
  }

  func testEveryCloudRouteBoundsEscapedUnicodeAndManualModels() throws {
    for provider in CloudProviderID.allCases {
      for model in ["gpt-5.6-luna", "manual-unknown-model"] {
        let messages = [
          ChatMessage(role: .user, content: String(repeating: "older 👩🏽‍💻\n\"\\", count: 10_000)),
          ChatMessage(role: .assistant, content: "older reply"),
          ChatMessage(role: .user, content: "recent"),
          ChatMessage(role: .assistant, content: "answer"),
          ChatMessage(role: .user, content: "你好 👩🏽‍💻\n\"\\ current"),
        ]
        let request = request(messages, provider: provider, model: model)
        let prepared = try CloudContext.prepare(request)
        XCTAssertEqual(prepared.messages, Array(messages.suffix(3)))
        XCTAssertEqual(request.messages, messages)
        XCTAssertLessThanOrEqual(prepared.inputTokenCount, prepared.budget.availableInputTokens)
        XCTAssertEqual(try CloudContext.prepare(self.request(prepared.messages, provider: provider, model: model)).messages, prepared.messages)
      }
      let limit = ModelContextPolicy.cloud(provider: provider, modelID: "manual").availableInputTokens
      XCTAssertThrowsError(try CloudContext.prepare(request([
        ChatMessage(role: .user, content: String(repeating: "x", count: limit + 1)),
      ], provider: provider, model: "manual")))
    }
  }

  func testCloudSerializedInputJustUnderAtAndOverBudget() throws {
    for provider in CloudProviderID.allCases {
      let budget = ModelContextPolicy.cloud(provider: provider, modelID: "manual")
      let wrapperCount = try CloudContext.inputTokenCount([ChatMessage(role: .user, content: "x")], provider: provider) - 1
      let maximumLength = budget.availableInputTokens - wrapperCount
      for length in [maximumLength - 1, maximumLength] {
        let prepared = try CloudContext.prepare(request([
          ChatMessage(role: .user, content: String(repeating: "x", count: length)),
        ], provider: provider, model: "manual"))
        XCTAssertEqual(prepared.inputTokenCount, length + wrapperCount)
      }
      XCTAssertThrowsError(try CloudContext.prepare(request([
        ChatMessage(role: .user, content: String(repeating: "x", count: maximumLength + 1)),
      ], provider: provider, model: "manual")))
    }
  }

  func testModelMetadataAndAutoSharePolicyWithoutAssumingManual128K() {
    for provider in CloudProviderID.allCases {
      for id in ["gpt-5.6-luna", "my-manual-model"] {
        let model = CloudModel(id: id, displayName: id, provider: provider)
        let cloud = AutoRouter.CloudConfiguration(provider: provider, modelID: id)
        XCTAssertEqual(cloud.capabilities.maximumContextTokens, model.contextBudget.contextWindow)
      }
      XCTAssertLessThan(ModelContextPolicy.cloud(provider: provider, modelID: "manual").contextWindow, 128_000)
    }
  }

  func testNativeFormatterUsesAllMessagesAndAssistantGenerationPrefix() throws {
    let messages = [
      ChatMessage(role: .user, content: "Remember blåbær"),
      ChatMessage(role: .assistant, content: "I will remember blåbær"),
      ChatMessage(role: .user, content: "What did I ask you to remember?"),
    ]
    let formatted = try format(messages, template: "chatml")
    XCTAssertEqual(formatted, "<|im_start|>user\nRemember blåbær<|im_end|>\n<|im_start|>assistant\nI will remember blåbær<|im_end|>\n<|im_start|>user\nWhat did I ask you to remember?<|im_end|>\n<|im_start|>assistant\n")
    let other = try format([ChatMessage(role: .user, content: "Separate chat")], template: "chatml")
    XCTAssertFalse(other.contains("blåbær"))
    XCTAssertEqual(other, "<|im_start|>user\nSeparate chat<|im_end|>\n<|im_start|>assistant\n")
  }

  func testNativeFormatterDoesNotSilentlyDropHistoryForUnsupportedTemplates() throws {
    XCTAssertThrowsError(try format([ChatMessage(role: .user, content: "Hello")], template: "unsupported-template"))
    XCTAssertThrowsError(try format([ChatMessage(role: .user, content: "Hello")], template: ""))
    XCTAssertThrowsError(try format([ChatMessage(role: .user, content: "Hello\0hidden")], template: "chatml"))
  }

  private func prepare(_ messages: [ChatMessage]) throws -> PreparedConversation {
    try ChatContextPreparer.prepare(messages, budget: budget) { $0.reduce(0) { $0 + $1.content.utf8.count } }
  }

  private func request(_ messages: [ChatMessage], provider: CloudProviderID, model: String) -> ChatRequest {
    ChatRequest(sessionID: UUID(), messages: messages,
                route: Route(mode: .cloud, providerID: provider.rawValue, modelID: model, usesNetwork: true))
  }

  private func format(_ messages: [ChatMessage], template: String) throws -> String {
    try LocalChatBridge.formatted(messages, template: template)
  }
}
