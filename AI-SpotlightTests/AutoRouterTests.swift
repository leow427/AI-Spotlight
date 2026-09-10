import Foundation
import XCTest
@testable import Enigma

final class AutoRouterTests: XCTestCase {
  func testDemandingNaturalLanguagePromptsRouteToCloud() {
    let prompts = [
      "Design a fault-tolerant payment system that handles duplicate events and regional outages.",
      "Evaluate whether our expansion assumptions are internally consistent.",
      "Solve this problem: two trains leave opposite ends of a 300 km track at different speeds.",
      "Compare these three business strategies, assess their risks, and recommend the best option.",
      "Explain in depth how quantum tunnelling differs from classical motion.",
      "Create a comprehensive migration plan with dependencies, budget constraints, and rollback criteria.",
      "Calculate the probability of drawing three red balls without replacement.",
      "Which option is best given the trade-offs between reliability, cost, and performance?",
      "Think deeply about this question and challenge the assumptions before answering.",
      "Give me step–by–step reasoning for this decision.",
    ]
    for prompt in prompts {
      let decision = AutoRouter.decide(request(prompt: prompt))
      XCTAssertEqual(decision.route?.mode, .cloud, prompt)
      XCTAssertEqual(decision.reason, .requiresAdvancedReasoning, prompt)
    }
  }

  func testSimpleRequestsStillPreferLocal() {
    let prompts = [
      "Hi, how are you?",
      "Summarize this paragraph in three bullets.",
      "Make this email shorter and friendlier.",
      "Translate good morning into French.",
      "Explain why the sky is blue.",
      "Compare tea and coffee in one sentence.",
      "Write a story about a character called Eva.",
      "Tell me about the designer of this chair.",
    ]
    for prompt in prompts {
      let decision = AutoRouter.decide(request(prompt: prompt))
      XCTAssertEqual(decision.route?.mode, .local, prompt)
      XCTAssertEqual(decision.reason, .localPreferred, prompt)
    }
  }

  func testDetailedMultiRequirementPromptRoutesToCloudWithoutExactTriggerPhrases() {
    let prompt = """
      Help me choose between keeping our current supplier and switching to a new one.
      The current supplier has reliable delivery but charges more, requires a large
      minimum order, and only accepts payment in advance. The new supplier offers a
      lower unit price and smaller orders, but has a longer lead time and has never
      worked with our team. We only have enough cash for two months of inventory,
      and missing deliveries would put our largest customer at risk. Account for
      the effect of each option on working capital, service quality, and our ability
      to recover if something goes wrong. Include the assumptions behind your answer
      and tell me which missing facts could change it. Give me a recommendation
      with a practical sequence of next steps that our small team could carry out.
      """
    let decision = AutoRouter.decide(request(prompt: prompt))
    XCTAssertEqual(decision.route?.mode, .cloud)
    XCTAssertEqual(decision.reason, .requiresAdvancedReasoning)
  }

  func testLengthAloneDoesNotEscalateAnOrdinarySummary() {
    let decision = AutoRouter.decide(request(
      prompt: "Summarize this passage: " + String(repeating: "The garden is green. ", count: 60)
    ))
    XCTAssertEqual(decision.route?.mode, .local)
    XCTAssertEqual(decision.reason, .localPreferred)
  }

  func testComplexityDoesNotOverrideLocalModeOrDisconnectedCloud() {
    let prompt = "This is private. Design a resilient payment system and evaluate its failure modes."
    let localDecision = AutoRouter.decide(request(selectedMode: .local, prompt: prompt))
    let disconnectedDecision = AutoRouter.decide(AutoRouter.Request(
      selectedMode: .auto,
      prompt: prompt,
      contextMessages: [],
      localModel: localModel,
      cloud: nil
    ))
    for decision in [localDecision, disconnectedDecision] {
      XCTAssertEqual(decision.route?.mode, .local)
      XCTAssertFalse(decision.route?.usesNetwork ?? true)
    }
    XCTAssertEqual(localDecision.reason, .explicitMode)
    XCTAssertEqual(disconnectedDecision.reason, .cloudUnavailable)
  }

  func testComplexityStillRequiresAnAvailableReasoningCapableModel() {
    let basicCloud = AutoRouter.CloudConfiguration(
      provider: .openAI,
      modelID: "basic-cloud-model",
      capabilities: .localDefault
    )
    let decision = AutoRouter.decide(request(
      prompt: "Evaluate the assumptions behind this strategy.", cloud: basicCloud
    ))
    let capableLocal = AutoRouter.ModelCapabilities(
      maximumContextTokens: 4_096,
      supportsCoding: false,
      supportsWebSearch: false,
      reasoningLevel: .advanced
    )
    let localDecision = AutoRouter.decide(request(
      prompt: "Evaluate the assumptions behind this strategy.",
      localCapabilities: capableLocal,
      cloud: basicCloud
    ))
    XCTAssertNil(decision.route)
    XCTAssertEqual(decision.limitation, .unavailableCapability(.advancedReasoning))
    XCTAssertEqual(localDecision.route?.mode, .local)
  }

  func testOrdinaryWritingPrefersTheLowestLatencyLocalRoute() {
    let decision = AutoRouter.decide(request(prompt: "Draft a warm thank-you note."))

    XCTAssertEqual(decision.route?.mode, .local)
    XCTAssertFalse(decision.route?.usesNetwork ?? true)
    XCTAssertEqual(decision.reason, .localPreferred)
  }

  func testExplicitModesOverrideAutoRouting() {
    let localDecision = AutoRouter.decide(request(selectedMode: .local, prompt: "Write Swift code."))
    let cloudDecision = AutoRouter.decide(request(selectedMode: .cloud, prompt: "Summarize this."))

    XCTAssertEqual(localDecision.route?.mode, .local)
    XCTAssertEqual(localDecision.reason, .explicitMode)
    XCTAssertEqual(cloudDecision.route?.mode, .cloud)
    XCTAssertEqual(cloudDecision.reason, .explicitMode)
  }

  func testCloudDisconnectedSkipsAutomaticClassificationAndFallsBackToLocal() {
    XCTAssertFalse(AutoRouter.shouldRun(for: .auto, cloud: nil))

    let decision = AutoRouter.localFallback(localModel: localModel)

    XCTAssertEqual(decision.route?.mode, .local)
    XCTAssertEqual(decision.reason, .cloudUnavailable)
  }

  func testLocalModeNeverRunsAutomaticClassification() {
    XCTAssertFalse(AutoRouter.shouldRun(for: .local, cloud: cloud))
  }

  func testCodingAndComplexReasoningRouteToCloud() {
    let coding = AutoRouter.decide(request(prompt: "Implement this Swift function and debug the stack trace."))
    let reasoning = AutoRouter.decide(request(prompt: "Perform a root cause analysis and analyze the tradeoffs."))

    XCTAssertEqual(coding.route?.mode, .cloud)
    XCTAssertEqual(coding.reason, .requiresCoding)
    XCTAssertEqual(reasoning.route?.mode, .cloud)
    XCTAssertEqual(reasoning.reason, .requiresAdvancedReasoning)
  }

  func testContextBeyondTheLocalLimitRoutesToCloud() {
    let localCapabilities = AutoRouter.ModelCapabilities(
      maximumContextTokens: 600,
      supportsCoding: false,
      supportsWebSearch: false,
      reasoningLevel: .basic
    )
    let decision = AutoRouter.decide(request(
      prompt: String(repeating: "a", count: 1_000),
      localCapabilities: localCapabilities
    ))

    XCTAssertEqual(decision.route?.mode, .cloud)
    XCTAssertEqual(decision.reason, .exceedsLocalContext)
  }

  func testPrivacyWordingDoesNotOverrideAutoRouting() {
    let prefixes = [
      "Private information.", "This is private.", "Keep this private.",
      "Do not send this.", "Don't send this.", "Do not share this.",
      "Don't share this.", "Confidential.", "Sensitive personal information.",
    ]
    let prompts = [
      "Draft a warm thank-you note.",
      "Write Swift code for it.",
      "Evaluate the assumptions behind this strategy.",
      "Search the web for the latest news.",
    ]
    for prompt in prompts {
      let expected = AutoRouter.decide(request(prompt: prompt))
      for prefix in prefixes {
        let decision = AutoRouter.decide(request(prompt: prefix + " " + prompt))
        XCTAssertEqual(decision, expected, prefix + " " + prompt)
      }
    }
  }

  func testPrivateWordingDoesNotRequireALocalModelInAuto() {
    let decision = AutoRouter.decide(AutoRouter.Request(
      selectedMode: .auto,
      prompt: "This is private information. Draft a warm thank-you note.",
      contextMessages: [],
      localModel: nil,
      cloud: cloud
    ))

    XCTAssertEqual(decision.route?.mode, .cloud)
    XCTAssertEqual(decision.reason, .noLocalModel)
    XCTAssertTrue(decision.route?.usesNetwork ?? false)
    XCTAssertNil(decision.limitation)
  }

  func testWebRequestNeedsAWebCapableCloudModel() {
    let noWebDecision = AutoRouter.decide(request(prompt: "Search the web for the latest news."))
    let webCapabilities = AutoRouter.ModelCapabilities(
      maximumContextTokens: 128_000,
      supportsCoding: true,
      supportsWebSearch: true,
      reasoningLevel: .advanced
    )
    let webCloud = AutoRouter.CloudConfiguration(
      provider: .openAI,
      modelID: "web-model",
      capabilities: webCapabilities
    )
    let webDecision = AutoRouter.decide(request(
      prompt: "Search the web for the latest news.",
      cloud: webCloud
    ))

    XCTAssertNil(noWebDecision.route)
    XCTAssertEqual(noWebDecision.limitation, .unavailableCapability(.webSearch))
    XCTAssertEqual(webDecision.route?.mode, .cloud)
    XCTAssertEqual(webDecision.reason, .requiresWebSearch)
  }

  func testLongHistoryIsTrimmableButOversizedCurrentPromptIsRejected() {
    let longHistory = [
      ChatMessage(role: .user, content: String(repeating: "x", count: 50_000)),
      ChatMessage(role: .assistant, content: "answer"),
    ]
    let decision = AutoRouter.decide(AutoRouter.Request(
      selectedMode: .auto, prompt: "Continue", contextMessages: longHistory, localModel: localModel, cloud: cloud
    ))
    XCTAssertEqual(decision.route?.mode, .cloud)
    XCTAssertEqual(decision.reason, .exceedsLocalContext)
    let rejected = AutoRouter.decide(request(prompt: String(repeating: "x", count: 50_000)))
    XCTAssertNil(rejected.route)
    XCTAssertEqual(rejected.limitation, .unavailableCapability(.largerContext))
  }

  private let localModel = LocalModel(
    id: "local-model",
    displayName: "Local Model",
    fileURL: URL(fileURLWithPath: "/tmp/local-model.gguf")
  )

  private let cloud = AutoRouter.CloudConfiguration(
    provider: .openAI,
    modelID: "cloud-model"
  )

  private func request(
    selectedMode: ChatMode = .auto,
    prompt: String,
    localCapabilities: AutoRouter.ModelCapabilities = .localDefault,
    cloud: AutoRouter.CloudConfiguration? = nil
  ) -> AutoRouter.Request {
    AutoRouter.Request(
      selectedMode: selectedMode,
      prompt: prompt,
      contextMessages: [],
      localModel: localModel,
      localCapabilities: localCapabilities,
      cloud: cloud ?? self.cloud
    )
  }
}
