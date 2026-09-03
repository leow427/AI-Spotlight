import Combine
import Foundation

struct CloudPreferencesStore: @unchecked Sendable {
  private enum Key {
    static let preferredProvider = "aiSpotlight.cloud.preferredProvider"
    static func preferredModel(_ provider: CloudProviderID) -> String {
      "aiSpotlight.cloud.preferredModel.\(provider.rawValue)"
    }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func preferredProvider() -> CloudProviderID {
    defaults.string(forKey: Key.preferredProvider)
      .flatMap(CloudProviderID.init(rawValue:)) ?? .chatGPT
  }

  func setPreferredProvider(_ provider: CloudProviderID) {
    defaults.set(provider.rawValue, forKey: Key.preferredProvider)
  }

  func preferredModel(for provider: CloudProviderID) -> String {
    defaults.string(forKey: Key.preferredModel(provider)) ?? ""
  }

  func setPreferredModel(_ modelID: String, for provider: CloudProviderID) {
    defaults.set(modelID, forKey: Key.preferredModel(provider))
  }
}

@MainActor
final class CloudSettingsModel: ObservableObject {
  enum ConnectionState: Equatable {
    case idle
    case testing
    case connected(Int)
    case failed(String)
  }

  static let shared: CloudSettingsModel = {
    let credentialStore = KeychainCredentialStore()
    return CloudSettingsModel(
      credentialStore: credentialStore,
      catalog: CloudModelCatalog(
        credentialStore: credentialStore,
        transport: URLSessionCloudTransport.shared
      )
    )
  }()

  @Published var preferredProvider: CloudProviderID {
    didSet {
      guard preferredProvider != oldValue else { return }
      preferences.setPreferredProvider(preferredProvider)
      preferredModelID = preferences.preferredModel(for: preferredProvider)
      models = []
      discoveryError = nil
      Task { await loadCachedModels() }
    }
  }

  @Published var preferredModelID: String {
    didSet {
      preferences.setPreferredModel(
        preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines),
        for: preferredProvider
      )
    }
  }

  @Published private(set) var models: [CloudModel] = []
  @Published private(set) var discoveryError: String?
  @Published private(set) var isDiscovering = false
  @Published private(set) var credentialRevision = 0
  @Published private(set) var connectionStates: [CloudProviderID: ConnectionState] = [:]
  @Published private(set) var chatGPTAccount: CodexAccount?
  @Published private(set) var isSigningIn = false
  @Published private(set) var accountError: String?
  @Published private(set) var isCodexAvailable: Bool

  private let credentialStore: any CloudCredentialStore
  private let catalog: CloudModelCatalog
  private let preferences: CloudPreferencesStore
  private let codex: CodexSubscriptionClient
  private let codexAvailable: @Sendable () -> Bool
  private var loginTask: Task<Void, Never>?
  private var discoveryID = UUID()

  init(
    credentialStore: any CloudCredentialStore,
    catalog: CloudModelCatalog,
    preferences: CloudPreferencesStore = CloudPreferencesStore(),
    codex: CodexSubscriptionClient = .live,
    codexAvailable: @escaping @Sendable () -> Bool = { CodexRuntimeConfiguration.executableURL() != nil }
  ) {
    self.codex = codex
    self.codexAvailable = codexAvailable
    isCodexAvailable = codexAvailable()
    self.credentialStore = credentialStore
    self.catalog = catalog
    self.preferences = preferences
    let provider = preferences.preferredProvider()
    preferredProvider = provider
    preferredModelID = preferences.preferredModel(for: provider)
  }

  var isConfigured: Bool {
    hasCloudAccess(for: preferredProvider)
      && !preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func hasCloudAccess(for provider: CloudProviderID) -> Bool {
    provider == .chatGPT ? chatGPTAccount != nil : hasAPIKey(for: provider)
  }

  func refreshChatGPTAccount() async {
    guard !isSigningIn else { return }
    isCodexAvailable = codexAvailable()
    guard isCodexAvailable else { chatGPTAccount = nil; return }
    do {
      chatGPTAccount = try await codex.account()
      accountError = nil
    } catch {
      chatGPTAccount = nil
      accountError = error.localizedDescription
    }
  }

  func signInWithChatGPT(openURL: @escaping @Sendable (URL) async -> Bool) {
    guard !isSigningIn else { return }
    isSigningIn = true
    accountError = nil
    loginTask = Task {
      defer { isSigningIn = false; loginTask = nil }
      do {
        chatGPTAccount = try await codex.signIn(openURL: openURL)
        try await catalog.clearCache(for: .chatGPT)
        preferredProvider = .chatGPT
        await discoverModels(forceRefresh: true)
      } catch is CancellationError {
        // Cancelling the browser flow is not a connection error.
      } catch {
        accountError = error.localizedDescription
      }
    }
  }

  func cancelSignIn() { loginTask?.cancel() }

  func signOutOfChatGPT() async {
    guard !isSigningIn else { return }
    do {
      try await codex.signOut()
      chatGPTAccount = nil
      accountError = nil
      if preferredProvider == .chatGPT { models = [] }
      try await catalog.clearCache(for: .chatGPT)
    } catch {
      accountError = error.localizedDescription
    }
  }

  func hasAPIKey(for provider: CloudProviderID) -> Bool {
    guard provider != .chatGPT else { return false }
    guard let apiKey = try? credentialStore.apiKey(for: provider) else { return false }
    return !apiKey.isEmpty
  }

  func saveAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {
    guard provider != .chatGPT else { throw CodexError.notSignedIn }
    let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAPIKey.isEmpty else { return }
    try credentialStore.setAPIKey(trimmedAPIKey, for: provider)
    credentialRevision += 1
    connectionStates[provider] = .idle
  }

  func removeAPIKey(for provider: CloudProviderID) throws {
    try credentialStore.removeAPIKey(for: provider)
    credentialRevision += 1
    connectionStates[provider] = .idle
  }

  func loadCachedModels() async {
    let provider = preferredProvider
    if let cached = await catalog.cachedModels(for: provider), provider == preferredProvider {
      models = cached
      selectFirstModelIfNeeded()
    }
  }

  func discoverModels(forceRefresh: Bool = false) async {
    let provider = preferredProvider
    let id = UUID()
    discoveryID = id
    isDiscovering = true
    discoveryError = nil
    defer { if discoveryID == id { isDiscovering = false } }
    do {
      let discovered = try await catalog.models(
        for: provider,
        forceRefresh: forceRefresh
      )
      guard preferredProvider == provider, discoveryID == id else { return }
      models = discovered
      selectFirstModelIfNeeded()
    } catch {
      guard preferredProvider == provider, discoveryID == id else { return }
      models = []
      discoveryError = error.localizedDescription
    }
  }

  func testConnection(to provider: CloudProviderID) async {
    connectionStates[provider] = .testing
    do {
      let discovered = try await catalog.models(for: provider, forceRefresh: true)
      connectionStates[provider] = .connected(discovered.count)
      if provider == preferredProvider {
        models = discovered
        discoveryError = nil
        selectFirstModelIfNeeded()
      }
    } catch {
      connectionStates[provider] = .failed(error.localizedDescription)
    }
  }

  func connectionState(for provider: CloudProviderID) -> ConnectionState {
    connectionStates[provider] ?? .idle
  }

  private func selectFirstModelIfNeeded() {
    guard preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let firstModel = models.first else { return }
    preferredModelID = firstModel.id
  }
}
