import Foundation
import XCTest
@testable import Enigma

@MainActor
final class CloudModelSelectionTests: XCTestCase {
  func testMixedDiscoveryNeverDefaultsToAnImageOrEmbeddingModel() async throws {
    let (settings, _, transport) = makeSettings(ids: [
      "dall-e-3", "text-embedding-3-small", "gpt-4o-mini", "gpt-5.6-luna", "gpt-audio",
    ])

    await settings.discoverModels(forceRefresh: true)

    XCTAssertEqual(settings.preferredModelID, "gpt-5.6-luna")
    XCTAssertEqual(settings.models.map(\.id), ["gpt-5.6-luna", "gpt-4o-mini"])
    XCTAssertEqual(transport.dataRequests.count, 1)
    XCTAssertTrue(transport.streamRequests.isEmpty)
  }

  func testDefaultDoesNotDependOnProviderListOrderOrGPTNamePrefix() async throws {
    let ids = ["gpt-image-2", "gpt-unknown", "gpt-5.6-luna-audio", "gpt-4.1", "gpt-5.6-luna"]
    for offset in ids.indices {
      let shuffled = Array(ids[offset...]) + Array(ids[..<offset])
      let (settings, _, _) = makeSettings(ids: shuffled)
      await settings.discoverModels(forceRefresh: true)
      XCTAssertEqual(settings.preferredModelID, "gpt-5.6-luna")
      XCTAssertEqual(settings.models.map(\.id), ["gpt-5.6-luna", "gpt-4.1"])
    }
  }

  func testFallbackPrefersReviewedSmallModelInsteadOfAlphabeticalFirst() async {
    let (settings, _, _) = makeSettings(ids: ["gpt-4.1", "gpt-4o", "gpt-4.1-mini", "gpt-4o-mini"])
    await settings.discoverModels(forceRefresh: true)
    XCTAssertEqual(settings.preferredModelID, "gpt-4.1-mini")
  }

  func testEmptyIncompatibleAndUnknownListsAreSuccessfulConnectionsWithoutDefaults() async {
    for ids in [[], ["dall-e-3", "text-embedding-3-small"], ["gpt-future", "ft:gpt-future:custom"]] {
      let (settings, preferences, transport) = makeSettings(ids: ids)
      await settings.testConnection(to: .openAI)
      XCTAssertEqual(settings.connectionState(for: .openAI), .connected(0))
      XCTAssertTrue(settings.models.isEmpty)
      XCTAssertNil(settings.discoveryError)
      XCTAssertNotNil(settings.modelDiscoveryNotice)
      XCTAssertEqual(settings.selectedModelCompatibility, .unselected)
      XCTAssertEqual(settings.preferredModelID, "")
      XCTAssertEqual(preferences.preferredModel(for: .openAI), "")
      XCTAssertFalse(settings.isConfigured)
      XCTAssertEqual(transport.dataRequests.map(\.httpMethod), ["GET"])
      XCTAssertEqual(transport.dataRequests.first?.url?.path, "/v1/models")
      XCTAssertTrue(transport.streamRequests.isEmpty)
      await settings.loadCachedModels()
      XCTAssertNotNil(settings.modelDiscoveryNotice)
      XCTAssertEqual(settings.preferredModelID, "")
    }
  }

  func testLegacyCacheIsFilteredOnEveryReadWithoutNetworkOrPreferenceReplacement() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    struct Entry: Encodable { let fetchedAt: Date; let models: [CloudModel] }
    struct Archive: Encodable { let providers: [String: Entry] }
    let rawModels = ["dall-e-3", "gpt-audio", "gpt-4o-mini", "gpt-new", "gpt-5.6-luna", "gpt-4o-mini", ""]
      .map { CloudModel(id: $0, displayName: $0, provider: .openAI) }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(Archive(providers: ["openai": Entry(fetchedAt: .now, models: rawModels)]))
      .write(to: root.appending(path: "cloud-models.json"))
    let transport = SelectionTransport(ids: [])
    let catalog = CloudModelCatalog(credentialStore: SelectionCredentials(), transport: transport, cacheDirectory: root)
    let cached = await catalog.cachedModels(for: .openAI)
    let reused = try await catalog.models(for: .openAI)
    XCTAssertEqual(cached?.map(\.id), ["gpt-5.6-luna", "gpt-4o-mini"])
    XCTAssertEqual(reused, cached)
    let (_, preferences, _) = makeSettings(ids: [], selected: "gpt-4o-mini")
    let settings = CloudSettingsModel(
      credentialStore: SelectionCredentials(), catalog: catalog, preferences: preferences, codexAvailable: { false }
    )
    await settings.loadCachedModels()
    XCTAssertEqual(settings.models, reused)
    XCTAssertEqual(settings.preferredModelID, "gpt-4o-mini")
    XCTAssertEqual(settings.selectedModelCompatibility, .compatible)
    XCTAssertTrue(transport.dataRequests.isEmpty)
    XCTAssertTrue(transport.streamRequests.isEmpty)
  }

  func testSupportedSavedSelectionsSurviveRefreshCacheAndReloadEvenWhenNotListed() async {
    for selected in ["gpt-4o-mini", "gpt-4.1-mini-2025-04-14", "gpt-5.6-terra"] {
      let (settings, preferences, _) = makeSettings(ids: ["gpt-5.6-luna"], selected: selected)
      await settings.discoverModels(forceRefresh: true)
      await settings.loadCachedModels()
      await settings.testConnection(to: .openAI)
      XCTAssertEqual(settings.preferredModelID, selected)
      XCTAssertEqual(preferences.preferredModel(for: .openAI), selected)
      XCTAssertEqual(settings.selectedModelCompatibility, .compatible)
      XCTAssertTrue(settings.isConfigured)
      let restored = CloudSettingsModel(
        credentialStore: SelectionCredentials(),
        catalog: CloudModelCatalog(credentialStore: SelectionCredentials(), transport: SelectionTransport(ids: []), cacheDirectory: temporaryDirectory()),
        preferences: preferences, codexAvailable: { false }
      )
      XCTAssertEqual(restored.preferredModelID, selected)
      XCTAssertTrue(restored.isConfigured)
    }
  }

  func testManualSelectionFeedbackAndPersistenceAreIndependentOfDiscovery() async {
    let (settings, preferences, _) = makeSettings(ids: ["gpt-5.6-luna"])
    let cases: [(String, CloudModelCompatibility)] = [
      ("gpt-4o-mini", .compatible),
      ("  gpt-4.1-mini-2025-04-14 \n", .compatible),
      ("text-embedding-3-large", .unsupported),
      ("dall-e-3", .unsupported),
      ("gpt-4o-audio-preview", .unsupported),
      ("gpt-future-model", .unverified),
      ("ft:gpt-4o-mini-2024-07-18:organization:custom:id", .unverified),
    ]
    for (id, expected) in cases {
      settings.preferredModelID = id
      XCTAssertEqual(settings.selectedModelCompatibility, expected, id)
      XCTAssertEqual(settings.isConfigured, expected.allowsSending, id)
      await settings.discoverModels(forceRefresh: true)
      XCTAssertEqual(settings.preferredModelID, id, "Refresh must keep explicit input")
      XCTAssertEqual(preferences.preferredModel(for: .openAI), id.trimmingCharacters(in: .whitespacesAndNewlines))
      XCTAssertEqual(settings.selectedModelCompatibility, expected)
    }
  }

  func testAccountCheckCannotMakeUnsupportedSelectionReadyForChat() async {
    let (settings, preferences, transport) = makeSettings(ids: ["gpt-5.6-luna"], selected: "dall-e-3")
    await settings.testConnection(to: .openAI)
    XCTAssertEqual(settings.connectionState(for: .openAI), .connected(1))
    XCTAssertEqual(settings.selectedModelCompatibility, .unsupported)
    XCTAssertFalse(settings.isConfigured)
    XCTAssertEqual(preferences.preferredModel(for: .openAI), "dall-e-3")
    settings.preferredModelID = "gpt-5.6-luna"
    XCTAssertTrue(settings.isConfigured)
    settings.preferredModelID = "gpt-image-2"
    XCTAssertFalse(settings.isConfigured)
    XCTAssertEqual(settings.connectionState(for: .openAI), .connected(1), "Account reachability is a separate result")
    XCTAssertEqual(transport.dataRequests.count, 1)
    XCTAssertTrue(transport.streamRequests.isEmpty, "Connection testing must never generate a billable response")
  }

  func testCompatibilityDoesNotClaimCredentialAccess() {
    let (_, preferences, _) = makeSettings(ids: [], selected: "gpt-5.6-luna")
    let credentials = SelectionCredentials(key: nil)
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: SelectionTransport(ids: []), cacheDirectory: temporaryDirectory()),
      preferences: preferences, codexAvailable: { false }
    )
    XCTAssertEqual(settings.selectedModelCompatibility, .compatible)
    XCTAssertFalse(settings.hasCloudAccess(for: .openAI))
    XCTAssertFalse(settings.isConfigured)
  }

  func testUnknownModelsAndUnreviewedSnapshotsAreNeverCertifiedByName() {
    for id in ["gpt-5.6-luna-2099-01-01", "gpt-4o-mini-custom", "GPT-4o-mini", "gpt-future", "ft:gpt-4o-mini:custom"] {
      XCTAssertEqual(CloudModelCapabilities.compatibility(provider: .openAI, modelID: id), .unverified)
      XCTAssertEqual(ModelContextPolicy.cloud(provider: .openAI, modelID: id).contextWindow, 8_192)
    }
    XCTAssertEqual(CloudModelCapabilities.compatibility(provider: .openAI, modelID: " \n "), .unselected)
    XCTAssertEqual(CloudModelCapabilities.compatibility(provider: .anthropic, modelID: "gpt-5.6-luna"), .unverified)
    XCTAssertEqual(ModelContextPolicy.cloud(provider: .anthropic, modelID: "gpt-5.6-luna").contextWindow, 8_192)
    XCTAssertEqual(CloudModelCapabilities.compatibility(provider: .chatGPT, modelID: "gpt-5.6"), .unverified)
  }

  func testReviewedSnapshotCanBeSelectedWithoutItsAlias() async {
    let (settings, _, _) = makeSettings(ids: ["gpt-image-2", "gpt-4o-mini-2024-07-18"])
    await settings.discoverModels(forceRefresh: true)
    XCTAssertEqual(settings.preferredModelID, "gpt-4o-mini-2024-07-18")
    XCTAssertEqual(settings.selectedModelCompatibility, .compatible)
    XCTAssertTrue(settings.isConfigured)
  }

  func testEmptyDuplicateAndWrongProviderCacheEntriesCannotBecomeDefaults() {
    let entries = [
      CloudModel(id: "", displayName: "Empty", provider: .openAI),
      CloudModel(id: " \n", displayName: "Whitespace", provider: .openAI),
      CloudModel(id: "gpt-5.6-luna", displayName: "Wrong provider", provider: .anthropic),
      CloudModel(id: "gpt-4o-mini", displayName: "First", provider: .openAI),
      CloudModel(id: "gpt-4o-mini", displayName: "Duplicate", provider: .openAI),
    ]
    XCTAssertEqual(CloudModelCapabilities.chatModels(entries, for: .openAI), [entries[3]])
  }

  func testCompatibleAndUnknownManualModelsStillReachResponsesWithBoundedRequests() async throws {
    for id in ["gpt-4o-mini-2024-07-18", "gpt-5.6", "ft:gpt-4o-mini-2024-07-18:custom"] {
      let transport = SelectionTransport(ids: [])
      let client = OpenAIResponsesClient(credentialStore: SelectionCredentials(), transport: transport)
      var events: [ChatEvent] = []
      for try await event in client.stream(request(modelID: id)) { events.append(event) }
      XCTAssertEqual(events, [.completed])
      let sent = try XCTUnwrap(transport.streamRequests.first)
      XCTAssertEqual(sent.url?.path, "/v1/responses")
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
      XCTAssertEqual(body["model"] as? String, id)
      XCTAssertEqual(body["max_output_tokens"] as? Int, 4_096)
      XCTAssertEqual(body["store"] as? Bool, false)
      XCTAssertEqual(body["stream"] as? Bool, true)
      XCTAssertTrue(transport.dataRequests.isEmpty)
    }
  }

  func testUnsupportedModelsFailAtRequestBoundaryBeforeAnyNetwork() async {
    let transport = SelectionTransport(ids: [])
    let client = OpenAIResponsesClient(credentialStore: SelectionCredentials(), transport: transport)
    for id in ["dall-e-3", "gpt-image-2", "text-embedding-3-small", "gpt-audio", "gpt-4o-mini-realtime-preview", "whisper-1", "sora-2", "omni-moderation-latest"] {
      do {
        for try await _ in client.stream(request(modelID: id)) {}
        XCTFail("Unsupported model was sent: \(id)")
      } catch {
        XCTAssertEqual(error as? CloudProviderError, .unsupportedModel(.openAI, modelID: id))
      }
    }
    XCTAssertTrue(transport.streamRequests.isEmpty)
    XCTAssertTrue(transport.dataRequests.isEmpty)
  }

  func testRejectedUnsupportedModelPreservesDraftAndTranscript() throws {
    let root = temporaryDirectory()
    let store = ChatSessionStore(applicationSupportDirectory: root)
    try store.save([ChatSession(messages: [
      ChatMessage(role: .user, content: "Earlier question"),
      ChatMessage(role: .assistant, content: "Earlier answer"),
    ])])
    let baseline = store.load()
    let transport = SelectionTransport(ids: [])
    let viewModel = LocalChatViewModel(
      engine: LlamaCPPModelEngine(installationStore: LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))),
      cloudProviders: CloudProviderRegistry(credentialStore: SelectionCredentials(), transport: transport),
      sessionStore: store
    )
    let original = "  Keep my exact draft.\n"
    var draft = original
    viewModel.submitCloud(draft, provider: .openAI, modelID: "dall-e-3", onAccepted: { draft = "" })
    XCTAssertEqual(draft, original)
    XCTAssertEqual(viewModel.messages, baseline[0].messages)
    XCTAssertEqual(store.load(), baseline)
    XCTAssertFalse(viewModel.isBusy)
    XCTAssertNil(viewModel.activeRequest)
    guard case .failed(let message) = viewModel.state else { return XCTFail("Expected an actionable rejection") }
    XCTAssertTrue(message.contains("Choose a compatible model"))
    XCTAssertTrue(transport.streamRequests.isEmpty)
  }

  func testSelectionChangedDuringAccountCheckIsPreserved() async {
    let started = expectation(description: "Model-list request started")
    let gate = SelectionResponseGate()
    let (settings, preferences, _) = makeSettings(ids: [], dataHandler: { _ in
      started.fulfill()
      return await gate.response()
    })
    let check = Task { await settings.testConnection(to: .openAI) }
    await fulfillment(of: [started], timeout: 2)
    settings.preferredModelID = "my-manual-model"
    await gate.release(models: ["gpt-5.6-luna"])
    await check.value
    XCTAssertEqual(settings.preferredModelID, "my-manual-model")
    XCTAssertEqual(preferences.preferredModel(for: .openAI), "my-manual-model")
    XCTAssertEqual(settings.selectedModelCompatibility, .unverified)
    XCTAssertTrue(settings.isConfigured)
  }

  func testProviderChangeDuringDiscoveryDoesNotReplaceOtherProvidersPreference() async {
    let started = expectation(description: "OpenAI model-list request started")
    let gate = SelectionResponseGate()
    let (settings, preferences, _) = makeSettings(ids: [], selected: "gpt-4o-mini", dataHandler: { _ in
      started.fulfill()
      return await gate.response()
    })
    preferences.setPreferredModel("claude-manual", for: .anthropic)
    let discovery = Task { await settings.discoverModels(forceRefresh: true) }
    await fulfillment(of: [started], timeout: 2)
    settings.preferredProvider = .anthropic
    await gate.release(models: ["gpt-5.6-luna"])
    await discovery.value
    XCTAssertEqual(settings.preferredProvider, .anthropic)
    XCTAssertEqual(settings.preferredModelID, "claude-manual")
    XCTAssertTrue(settings.models.isEmpty)
    settings.preferredProvider = .openAI
    await settings.loadCachedModels()
    XCTAssertEqual(settings.preferredModelID, "gpt-4o-mini")
    XCTAssertEqual(settings.selectedModelCompatibility, .compatible)
  }

  func testDiscoveryFailuresKeepManualChoiceAndDoNotCertifyCompatibility() async {
    let responses = [
      CloudDataResponse(data: Data("{\"error\":{\"message\":\"Denied\"}}".utf8), statusCode: 401),
      CloudDataResponse(data: Data("not-json".utf8), statusCode: 200),
    ]
    for response in responses {
      let (settings, preferences, transport) = makeSettings(ids: [], selected: "manual-id", dataHandler: { _ in response })
      await settings.discoverModels(forceRefresh: true)
      XCTAssertNotNil(settings.discoveryError)
      XCTAssertNil(settings.modelDiscoveryNotice)
      await settings.testConnection(to: .openAI)
      guard case .failed = settings.connectionState(for: .openAI) else { return XCTFail("Expected connection failure") }
      XCTAssertEqual(settings.preferredModelID, "manual-id")
      XCTAssertEqual(preferences.preferredModel(for: .openAI), "manual-id")
      XCTAssertEqual(settings.selectedModelCompatibility, .unverified)
      XCTAssertTrue(transport.streamRequests.isEmpty)
    }
  }

  func testAnthropicDiscoveryRetainsProviderOrderAndManualChoices() async {
    let (settings, preferences, _) = makeSettings(ids: ["claude-newer", "claude-older"])
    settings.preferredProvider = .anthropic
    await settings.discoverModels(forceRefresh: true)
    XCTAssertEqual(settings.models.map(\.id), ["claude-newer", "claude-older"])
    XCTAssertEqual(settings.preferredModelID, "claude-newer")
    XCTAssertEqual(settings.selectedModelCompatibility, .compatible)
    settings.preferredModelID = "claude-manual"
    await settings.testConnection(to: .anthropic)
    XCTAssertEqual(settings.preferredModelID, "claude-manual")
    XCTAssertEqual(preferences.preferredModel(for: .anthropic), "claude-manual")
    XCTAssertEqual(settings.selectedModelCompatibility, .unverified)
    XCTAssertTrue(settings.isConfigured)
  }

  func testReviewedModelsUseSharedContextLimitsAtRequestBoundaries() throws {
    for (id, window) in [
      ("gpt-4o-mini-2024-07-18", 128_000), ("gpt-4.1-mini", 1_047_576),
      ("gpt-5.4-mini", 400_000), ("gpt-5.6", 1_050_000),
    ] {
      let model = CloudModel(id: id, displayName: id, provider: .openAI)
      let budget = model.contextBudget
      XCTAssertEqual(budget.contextWindow, window)
      XCTAssertEqual(AutoRouter.CloudConfiguration(provider: .openAI, modelID: id).capabilities.maximumContextTokens, window)
      XCTAssertEqual(budget.outputTokens, 4_096)
      XCTAssertEqual(budget.overheadTokens, 512)
      let wrapper = try CloudContext.inputTokenCount([ChatMessage(role: .user, content: "x")], provider: .openAI) - 1
      let maximum = budget.availableInputTokens - wrapper
      for length in [maximum - 1, maximum] {
        let prepared = try CloudContext.prepare(request(modelID: id, prompt: String(repeating: "x", count: length)))
        XCTAssertLessThanOrEqual(prepared.inputTokenCount + budget.outputTokens + budget.overheadTokens, window)
      }
      XCTAssertThrowsError(try CloudContext.prepare(request(modelID: id, prompt: String(repeating: "x", count: maximum + 1))))
    }
  }

  private func request(modelID: String, prompt: String = "Hello") -> ChatRequest {
    ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: prompt)], route: Route(
      mode: .cloud, providerID: CloudProviderID.openAI.rawValue, modelID: modelID, usesNetwork: true
    ))
  }

  private func makeSettings(
    ids: [String], selected: String = "", dataHandler: SelectionTransport.DataHandler? = nil
  ) -> (CloudSettingsModel, CloudPreferencesStore, SelectionTransport) {
    let suite = "CloudModelSelectionTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let preferences = CloudPreferencesStore(defaults: defaults)
    preferences.setPreferredProvider(.openAI)
    preferences.setPreferredModel(selected, for: .openAI)
    let credentials = SelectionCredentials()
    let transport = SelectionTransport(ids: ids, dataHandler: dataHandler)
    let catalog = CloudModelCatalog(
      credentialStore: credentials, transport: transport, cacheDirectory: temporaryDirectory()
    )
    return (CloudSettingsModel(
      credentialStore: credentials, catalog: catalog, preferences: preferences,
      codexAvailable: { false }
    ), preferences, transport)
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "CloudModelSelection-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}

private struct SelectionCredentials: CloudCredentialStore {
  var key: String? = "test-only-key"
  func apiKey(for provider: CloudProviderID) throws -> String? { key }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {}
  func removeAPIKey(for provider: CloudProviderID) throws {}
}

private final class SelectionTransport: CloudNetworkTransport, @unchecked Sendable {
  typealias DataHandler = @Sendable (URLRequest) async throws -> CloudDataResponse
  private let lock = NSLock()
  private let ids: [String]
  private let dataHandler: DataHandler?
  private var storedDataRequests: [URLRequest] = []
  private var storedStreamRequests: [URLRequest] = []

  init(ids: [String], dataHandler: DataHandler? = nil) {
    self.ids = ids
    self.dataHandler = dataHandler
  }

  var dataRequests: [URLRequest] { lock.withLock { storedDataRequests } }
  var streamRequests: [URLRequest] { lock.withLock { storedStreamRequests } }

  func data(for request: URLRequest) async throws -> CloudDataResponse {
    lock.withLock { storedDataRequests.append(request) }
    if let dataHandler { return try await dataHandler(request) }
    return CloudDataResponse(
      data: try JSONSerialization.data(withJSONObject: ["data": ids.map { ["id": $0, "display_name": $0] }]),
      statusCode: 200
    )
  }

  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    lock.withLock { storedStreamRequests.append(request) }
    return AsyncThrowingStream { continuation in
      continuation.yield(.response(statusCode: 200))
      continuation.yield(.data(Data("data: {\"type\":\"response.completed\"}\n\n".utf8)))
      continuation.finish()
    }
  }
}

private actor SelectionResponseGate {
  private var continuation: CheckedContinuation<CloudDataResponse, Never>?
  private var ready: CloudDataResponse?

  func response() async -> CloudDataResponse {
    if let ready { return ready }
    return await withCheckedContinuation { continuation = $0 }
  }

  func release(models: [String]) {
    let data = try! JSONSerialization.data(withJSONObject: ["data": models.map { ["id": $0] }])
    let response = CloudDataResponse(data: data, statusCode: 200)
    ready = response
    continuation?.resume(returning: response)
    continuation = nil
  }
}
