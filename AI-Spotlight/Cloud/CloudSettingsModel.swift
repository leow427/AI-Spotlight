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
      .flatMap(CloudProviderID.init(rawValue:)) ?? .openAI
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
    let sessionStore = KeychainCloudAccountSessionStore()
    let backend = CloudBackendConfiguration.live
    let transport = URLSessionCloudTransport.shared
    let accessResolver = PreferredCloudAccessResolver(
      credentialStore: credentialStore,
      sessionStore: sessionStore,
      backend: backend
    )
    return CloudSettingsModel(
      credentialStore: credentialStore,
      catalog: CloudModelCatalog(
        accessResolver: accessResolver,
        transport: transport
      ),
      accessResolver: accessResolver,
      sessionStore: sessionStore,
      accountAuthenticator: URLSessionCloudAccountClient(
        backend: backend,
        transport: transport
      ),
      backend: backend
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
  @Published private(set) var isSignedIn = false
  @Published private(set) var isSigningIn = false
  @Published private(set) var accountError: String?

  private let credentialStore: any CloudCredentialStore
  private let catalog: CloudModelCatalog
  private let preferences: CloudPreferencesStore
  private let accessResolver: any CloudAccessResolving
  private let sessionStore: any CloudAccountSessionStoring
  private let accountAuthenticator: any CloudAccountAuthenticating
  private let backend: CloudBackendConfiguration

  init(
    credentialStore: any CloudCredentialStore,
    catalog: CloudModelCatalog,
    accessResolver: any CloudAccessResolving,
    sessionStore: any CloudAccountSessionStoring,
    accountAuthenticator: any CloudAccountAuthenticating,
    backend: CloudBackendConfiguration,
    preferences: CloudPreferencesStore = CloudPreferencesStore()
  ) {
    self.credentialStore = credentialStore
    self.catalog = catalog
    self.accessResolver = accessResolver
    self.sessionStore = sessionStore
    self.accountAuthenticator = accountAuthenticator
    self.backend = backend
    self.preferences = preferences
    let provider = preferences.preferredProvider()
    preferredProvider = provider
    preferredModelID = preferences.preferredModel(for: provider)
    isSignedIn = (try? sessionStore.session()) != nil
  }

  var isConfigured: Bool {
    hasCloudAccess(for: preferredProvider)
      && !preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var isAccountSignInAvailable: Bool { backend.isConfigured }

  func hasCloudAccess(for provider: CloudProviderID) -> Bool {
    (try? accessResolver.access(for: provider)) != nil
  }

  func hasAPIKey(for provider: CloudProviderID) -> Bool {
    guard let apiKey = try? credentialStore.apiKey(for: provider) else { return false }
    return !apiKey.isEmpty
  }

  func saveAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {
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

  func signInWithApple(identityToken: Data, nonce: String) async {
    guard !isSigningIn else { return }
    isSigningIn = true
    accountError = nil
    defer { isSigningIn = false }
    do {
      let session = try await accountAuthenticator.signIn(
        identityToken: identityToken,
        nonce: nonce
      )
      try sessionStore.setSession(session)
      isSignedIn = true
      credentialRevision += 1
      models = []
      await discoverModels(forceRefresh: true)
    } catch {
      accountError = error.localizedDescription
      isSignedIn = false
    }
  }

  func signOut() {
    do {
      try sessionStore.removeSession()
      isSignedIn = false
      accountError = nil
      credentialRevision += 1
      models = []
      Task { await loadCachedModels() }
    } catch {
      accountError = error.localizedDescription
    }
  }

  func loadCachedModels() async {
    if let cached = await catalog.cachedModels(for: preferredProvider) {
      models = cached
      selectFirstModelIfNeeded()
    }
  }

  func discoverModels(forceRefresh: Bool = false) async {
    isDiscovering = true
    discoveryError = nil
    defer { isDiscovering = false }
    do {
      models = try await catalog.models(
        for: preferredProvider,
        forceRefresh: forceRefresh
      )
      selectFirstModelIfNeeded()
    } catch {
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
