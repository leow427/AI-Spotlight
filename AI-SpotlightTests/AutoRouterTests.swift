import Foundation
import XCTest
@testable import PrimaryAgent

final class AutoRouterTests: XCTestCase {
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

  func testExplicitPrivacyKeepsTheRequestLocalEvenWhenItNeedsCode() {
    let decision = AutoRouter.decide(request(
      prompt: "This is private information. Write Swift code for it."
    ))

    XCTAssertEqual(decision.route?.mode, .local)
    XCTAssertEqual(decision.reason, .privateRequest)
    XCTAssertFalse(decision.route?.usesNetwork ?? true)
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
